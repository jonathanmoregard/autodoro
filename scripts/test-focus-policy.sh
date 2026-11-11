#!/usr/bin/env bash
# Truth-table test for autodoro_focus.py: when the blocker may re-present
# itself, and when a screensaver state change dismisses it. Pure Python,
# no GTK or display needed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHONPATH="$REPO_DIR" python3 - <<'EOF'
from autodoro_focus import PresentPolicy, lock_transition

fails = 0
def check(name, got, want):
    global fails
    ok = got == want
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": got {got!r}, want {want!r}"))
    fails += not ok

# --- present: hard refusals ---
p = PresentPolicy(dev_mode=False)
check("locked never presents", p.decide(locked=True, is_active=False, now=0), False)
check("already-active window not presented", p.decide(locked=False, is_active=True, now=0), False)
check("dev mode never presents", PresentPolicy(dev_mode=True).decide(False, False, 0), False)
check("refusals consume no budget", len(p._attempts), 0)

# --- present: normal focus loss ---
check("unlocked + inactive presents", p.decide(False, False, 0), True)

# --- present: rate cap (3 per 60s) ---
p = PresentPolicy(dev_mode=False)
got = [p.decide(False, False, t) for t in (0, 1, 2, 3, 4)]
check("cap allows 3 then refuses", got, [True, True, True, False, False])
check("capped flag set while refusing", p.capped, True)
check("still refused just inside window", p.decide(False, False, 59.9), False)
check("allowed again once window slides", p.decide(False, False, 60.0), True)
check("capped flag clears", p.capped, False)

# The old 2 Hz loop over 10 minutes: 1200 asks must yield at most 30 presents.
p = PresentPolicy(dev_mode=False)
n = sum(p.decide(False, False, i * 0.5) for i in range(1200))
check("2 Hz for 10 min bounded to 30 presents", n, 30)

# Locked for the whole stretch: zero requests to the WM.
p = PresentPolicy(dev_mode=False)
n = sum(p.decide(True, False, i * 0.5) for i in range(1200))
check("locked for 10 min: zero presents", n, 0)

# --- lock transitions ---
check("unlocked at start: no exit", lock_transition(False, False), (False, False))
check("lock: no exit", lock_transition(False, True), (True, False))
check("stays locked: no exit", lock_transition(True, True), (True, False))
check("unlock edge: exit", lock_transition(True, False), (False, True))

raise SystemExit(1 if fails else 0)
EOF
echo "PASS: focus policy"
