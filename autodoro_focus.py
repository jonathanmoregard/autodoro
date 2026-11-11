"""Pure policy for the blocker's focus and lock handling.

Kept apart from autodoro_blocker.py, which runs its whole body on
import and needs a GTK main loop, an X display and a screensaver to do
anything at all. These are the decisions worth being sure about, and
here they can be tested as a truth table (scripts/test-focus-policy.sh).
"""

# At most PRESENT_CAP re-presents per PRESENT_WINDOW_SECS. A focus loss
# the WM keeps re-imposing (another fullscreen client, a locker this
# process failed to see) then costs a handful of requests a minute
# instead of a fight with the WM at the old 2 Hz.
PRESENT_CAP = 3
PRESENT_WINDOW_SECS = 60.0


class PresentPolicy:
    """Should the blocker raise itself and take keyboard focus now?

    Asked once per focus-lost edge (notify::is-active -> False), after a
    debounce, plus once shortly after the window maps (a window the WM
    never focused produces no edge). Never on a repeating timer.

    `--dev`: never. There is no WM stealing focus in a headless run, and
    a window that grabs focus makes UI iteration unusable.

    LOCKED: never, and this is the one that matters. The blocker used to
    ask for focus every 500ms unconditionally, so while the screen was
    locked it and cinnamon-screensaver were both asking muffin for focus
    several times a second -- a fight the blocker must not join, because
    the locker is supposed to be on top. That produced the sustained
    ~120 _NET_ACTIVE_WINDOW requests/minute seen on 2026-11-09 and
    2026-11-11. Stranded focus after unlock needs no re-present either:
    unlocking dismisses the blocker (see lock_transition).

    Otherwise: only when the window is still inactive at decision time,
    and only within the rate cap.
    """

    def __init__(self, dev_mode, cap=PRESENT_CAP, window=PRESENT_WINDOW_SECS):
        self.dev_mode = dev_mode
        self.cap = cap
        self.window = window
        self._attempts = []
        self.capped = False  # True while the cap is refusing; for logging edges

    def decide(self, locked, is_active, now):
        """Return True to present now (and record the attempt)."""
        if self.dev_mode or locked or is_active:
            return False
        self._attempts = [t for t in self._attempts if now - t < self.window]
        if len(self._attempts) >= self.cap:
            self.capped = True
            return False
        self.capped = False
        self._attempts.append(now)
        return True


def lock_transition(prev_locked, now_locked):
    """(new_state, exit_now) for one screensaver active-state observation.

    The blocker dismisses itself when the user locks the screen and then
    unlocks it: that is a deliberate "I am back" gesture and a break
    should not outlive it.

    Only the locked -> unlocked EDGE exits. Starting up while already
    unlocked must not, which is why this takes the previous state rather
    than just asking whether the screen is unlocked now -- the obvious
    version of this check would dismiss every break the instant it
    opened.
    """
    return now_locked, bool(prev_locked and not now_locked)
