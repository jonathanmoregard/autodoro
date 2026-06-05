#!/usr/bin/env bash

# --- CONFIGURATION DEFAULTS ---
# These are overridden by config.defaults, then by ~/.config/autodoro/config.
WORK_TIME=1500
POST_MEETING_TIME=900
WARNING_THRESHOLD=60
CHECK_INTERVAL=5
DELAY_UNLOCK_SECS=3
MAX_DELAYS=2
IDLE_PAUSE_SECS=300
PENALTY_AFTER_SESSIONS=2
MIC_EXCLUDE_PATTERNS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a key=value config file. Repeated keys like mic_exclude are accumulated.
_load_config() {
    local file="$1"
    [[ -f "$file" ]] || return
    while IFS='=' read -r key value; do
        key="${key%%#*}"                              # strip inline comments
        key="${key//[[:space:]]/}"                    # strip whitespace
        [[ -z "$key" ]] && continue
        value="${value%%#*}"                          # strip inline comments
        value="${value#"${value%%[![:space:]]*}"}"    # ltrim
        value="${value%"${value##*[![:space:]]}"}"    # rtrim
        case "$key" in
            work_time)           WORK_TIME="$value" ;;
            post_meeting_time)   POST_MEETING_TIME="$value" ;;
            warning_threshold)   WARNING_THRESHOLD="$value" ;;
            check_interval)      CHECK_INTERVAL="$value" ;;
            delay_unlock_secs)   DELAY_UNLOCK_SECS="$value" ;;
            max_delays)          MAX_DELAYS="$value" ;;
            idle_pause_secs)     IDLE_PAUSE_SECS="$value" ;;
            penalty_after_sessions) PENALTY_AFTER_SESSIONS="$value" ;;
            mic_exclude)         MIC_EXCLUDE_PATTERNS+=("$value") ;;
        esac
    done < "$file"
}
_load_config "$SCRIPT_DIR/config.defaults"
_load_config "${XDG_CONFIG_HOME:-$HOME/.config}/autodoro/config"

# --- ACROSS-RESTART STATE ---
# Persisted so the script can be restarted (e.g. by the pre-push
# deploy hook) without losing the anti-procrastination throttle's
# session-level counters. Reset by deleting this file.
STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/autodoro/state"
STATE_SCHEMA=1                # bump when the on-disk format changes
CONSEC_MAX_SKIP_SESSIONS=0    # consecutive sessions that hit MAX_DELAYS
PENALTY_REMAINING=0           # sessions left with skip disabled

# Coerce a state-file value to a non-negative integer. Empty / garbage
# / negative input → 0. Defends against torn writes and unknown future
# field types creeping into existing fields.
_as_uint() {
    case "$1" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$1" ;;
    esac
}

_load_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || return
    local schema=""
    while IFS='=' read -r key value; do
        value="${value%$'\r'}"   # strip a stray CR if the file ever picked one up
        case "$key" in
            schema)                   schema="$value" ;;
            consec_max_skip_sessions) CONSEC_MAX_SKIP_SESSIONS="$(_as_uint "$value")" ;;
            penalty_remaining)        PENALTY_REMAINING="$(_as_uint "$value")" ;;
        esac
    done < "$STATE_FILE"
    # Unknown future schema → wipe to current defaults rather than
    # trust fields we can't interpret. Same path as a missing file.
    if [ -n "$schema" ] && [ "$schema" != "$STATE_SCHEMA" ]; then
        echo "[$(date +%H:%M)] State schema $schema unknown (expected $STATE_SCHEMA); resetting throttle counters."
        CONSEC_MAX_SKIP_SESSIONS=0
        PENALTY_REMAINING=0
    fi
    # Drain stale state when the throttle is disabled by config —
    # otherwise a `penalty_remaining=N` left in the file would force
    # no-skip for one full work cycle before _on_session_end zeroed
    # it. Clamp otherwise so lowering penalty_after_sessions between
    # runs doesn't strand the user in a longer penalty than the new
    # config allows.
    if [ "$PENALTY_AFTER_SESSIONS" -le 0 ]; then
        PENALTY_REMAINING=0
        CONSEC_MAX_SKIP_SESSIONS=0
    elif [ "$PENALTY_REMAINING" -gt "$PENALTY_AFTER_SESSIONS" ]; then
        PENALTY_REMAINING=$PENALTY_AFTER_SESSIONS
    fi
}

# Atomic write: tempfile-in-same-dir + rename. A truncate-then-write
# (`cat > $STATE_FILE`) leaves a zero-byte file if the process is
# killed mid-heredoc, which silently reset the throttle on next start
# — exactly the regression the persistence is meant to prevent.
#
# A SIGKILL between mktemp and mv leaks one state.XXXXXX file. The
# sweep below catches those on the next _save_state call (cheap
# because the state dir holds one tiny file in steady state).
_save_state() {
    local dir tmp
    dir="$(dirname "$STATE_FILE")"
    mkdir -p "$dir"
    # Best-effort sweep of orphaned tempfiles from prior crashes.
    find "$dir" -maxdepth 1 -name 'state.??????' -type f -mmin +5 -delete 2>/dev/null || true
    tmp="$(mktemp "$dir/state.XXXXXX")"
    cat > "$tmp" <<EOF
schema=$STATE_SCHEMA
consec_max_skip_sessions=$CONSEC_MAX_SKIP_SESSIONS
penalty_remaining=$PENALTY_REMAINING
EOF
    mv -f "$tmp" "$STATE_FILE"
}
_load_state

# Called every time a real break ends (the blocker ran to completion,
# either via the popup-result LOCK path or the timer-expired failsafe).
# Updates the throttle counters using the just-finished session's
# DELAY_COUNT, then resets DELAY_COUNT.
#
# Lock-then-unlock and idle-reset deliberately skip this — the user
# didn't take an enforced break, so the throttle counters shouldn't
# move in either direction.
_on_session_end() {
    # Throttle disabled by config. Clear any leftover penalty state
    # so the user is not stranded inside an old penalty window after
    # flipping the knob off.
    if [ "$PENALTY_AFTER_SESSIONS" -le 0 ]; then
        if [ "$PENALTY_REMAINING" -ne 0 ] || [ "$CONSEC_MAX_SKIP_SESSIONS" -ne 0 ]; then
            PENALTY_REMAINING=0
            CONSEC_MAX_SKIP_SESSIONS=0
            _save_state
        fi
        DELAY_COUNT=0
        return
    fi
    # During a penalty session DELAY_COUNT is forced to 0 (the popup
    # disables the Delay button), so this branch is also the path
    # that drains an in-progress penalty.
    if [ "$PENALTY_REMAINING" -gt 0 ]; then
        PENALTY_REMAINING=$((PENALTY_REMAINING - 1))
        echo "[$(date +%H:%M)] Penalty: $PENALTY_REMAINING sessions of disabled skip remaining."
    elif [ "$DELAY_COUNT" -ge "$MAX_DELAYS" ]; then
        CONSEC_MAX_SKIP_SESSIONS=$((CONSEC_MAX_SKIP_SESSIONS + 1))
        echo "[$(date +%H:%M)] Skip-maxed session streak: $CONSEC_MAX_SKIP_SESSIONS/$PENALTY_AFTER_SESSIONS."
        if [ "$CONSEC_MAX_SKIP_SESSIONS" -ge "$PENALTY_AFTER_SESSIONS" ]; then
            PENALTY_REMAINING=$PENALTY_AFTER_SESSIONS
            CONSEC_MAX_SKIP_SESSIONS=0
            echo "[$(date +%H:%M)] Penalty triggered: skip disabled for $PENALTY_REMAINING sessions."
        fi
    else
        CONSEC_MAX_SKIP_SESSIONS=0
    fi
    DELAY_COUNT=0
    _save_state
}

WAS_IN_MEETING=false
WAS_LOCKED=false
WAS_IDLE=false
ZENITY_PID=""
POPUP_RESULT_FILE=""
TIMER=$WORK_TIME
DELAY_COUNT=0

echo "[$(date +%H:%M)] Autodoro: Monitoring mic via PipeWire/PulseAudio..."

while true; do
    # 0. LOCK DETECTION (Cinnamon-specific)
    # If the screensaver is active, don't count down, don't trigger popups.
    if cinnamon-screensaver-command -q 2>/dev/null | grep -q "is active"; then
        WAS_LOCKED=true
        sleep $CHECK_INTERVAL
        continue
    fi

    # Transition: Just unlocked - reset timer to give fresh start
    if [ "$WAS_LOCKED" = true ]; then
        echo "[$(date +%H:%M)] Screen unlocked. Resetting timer."
        TIMER=$WORK_TIME
        WAS_LOCKED=false
        # Kill any lingering popup
        [[ -n $ZENITY_PID ]] && kill $ZENITY_PID 2>/dev/null; ZENITY_PID=""
        [[ -n $POPUP_RESULT_FILE ]] && rm -f "$POPUP_RESULT_FILE"; POPUP_RESULT_FILE=""
        # Kill blocker if it was running during lock/logout
        BLOCKER_PID=$(cat /tmp/autodoro_blocker.pid 2>/dev/null)
        [[ -n $BLOCKER_PID ]] && kill $BLOCKER_PID 2>/dev/null
        rm -f /tmp/autodoro_blocker.pid
        pactl set-sink-mute @DEFAULT_SINK@ 0
    fi

    # 1. MEETING DETECTION
    # Find any mic source-output whose identifiers don't match an exclude pattern.
    # Matching is by source-output NAME (case-insensitive substring against
    # application.name, application.process.binary, and node.name), so we count
    # actual mic events rather than whether some process happens to be running.
    MIC_IN_USE=$(AUTODORO_EXCLUDES=$(printf '%s\n' "${MIC_EXCLUDE_PATTERNS[@]}") \
        pactl list source-outputs 2>/dev/null | python3 -c "
import sys, os
excludes = [p.lower() for p in os.environ.get('AUTODORO_EXCLUDES', '').splitlines() if p]
text = sys.stdin.read()
for block in text.split('\n\n'):
    name = binary = node = None
    for line in block.split('\n'):
        s = line.strip()
        if s.startswith('application.name = '):
            name = s.split('= ', 1)[1].strip('\"')
        elif s.startswith('application.process.binary = '):
            binary = s.split('= ', 1)[1].strip('\"')
        elif s.startswith('node.name = '):
            node = s.split('= ', 1)[1].strip('\"')
    if not name:
        continue
    fields = [f.lower() for f in (name, binary, node) if f]
    if any(pat in f for pat in excludes for f in fields):
        continue
    print('yes|' + name); break
" 2>/dev/null)
    if [[ "$MIC_IN_USE" == yes\|* ]]; then
        if [ "$WAS_IN_MEETING" = false ]; then
            echo "[$(date +%H:%M)] Meeting detected (${MIC_IN_USE#yes|}). Timer paused."
            WAS_IN_MEETING=true
            # Kill popup if it was open when meeting started
            [[ -n $ZENITY_PID ]] && kill $ZENITY_PID 2>/dev/null; ZENITY_PID=""
            [[ -n $POPUP_RESULT_FILE ]] && rm -f "$POPUP_RESULT_FILE"; POPUP_RESULT_FILE=""
        fi
        sleep $CHECK_INTERVAL
        continue # Skip the rest of the loop; timer is frozen
    fi

    # 2. TRANSITION: POST-MEETING
    if [ "$WAS_IN_MEETING" = true ]; then
        echo "[$(date +%H:%M)] Meeting ended. 15m grace period applied."
        TIMER=$POST_MEETING_TIME
        WAS_IN_MEETING=false
    fi

    # 3. WARNING POPUP LOGIC
    # Only trigger if timer is low AND no popup is already active.
    # Delay button disabled when either:
    #   (a) per-session limit reached (DELAY_COUNT >= MAX_DELAYS), or
    #   (b) currently inside a penalty window (PENALTY_REMAINING > 0).
    if [ $TIMER -le $WARNING_THRESHOLD ] && [ -z "$ZENITY_PID" ]; then
        if [ "$PENALTY_REMAINING" -gt 0 ]; then
            echo "[$(date +%H:%M)] Penalty active ($PENALTY_REMAINING sessions left). Forced break popup (no delay)."
            UNLOCK_SECS_ARG=-1
        elif [ $DELAY_COUNT -ge $MAX_DELAYS ]; then
            echo "[$(date +%H:%M)] Delay limit reached ($DELAY_COUNT/$MAX_DELAYS). Forced break popup (no delay)."
            UNLOCK_SECS_ARG=-1
        else
            echo "[$(date +%H:%M)] Triggering warning (Time remaining: ${TIMER}s)."
            UNLOCK_SECS_ARG=$DELAY_UNLOCK_SECS
        fi
        POPUP_RESULT_FILE=$(mktemp)
        CAPTURED_TIMER=$TIMER

        (
            python3 "$SCRIPT_DIR/autodoro_popup.py" "$CAPTURED_TIMER" "$UNLOCK_SECS_ARG"
            if [ $? -eq 0 ]; then
                echo "DELAY" > "$POPUP_RESULT_FILE"
            else
                echo "LOCK"  > "$POPUP_RESULT_FILE"
            fi
        ) &

        ZENITY_PID=$!
    fi

    # 4. MONITOR POPUP RESPONSE
    if [ -n "$ZENITY_PID" ]; then
        if ! ps -p $ZENITY_PID > /dev/null; then
            # Subshell finished; read result from tmpfile
            wait $ZENITY_PID
            RESULT=$(cat "$POPUP_RESULT_FILE" 2>/dev/null)
            rm -f "$POPUP_RESULT_FILE"
            POPUP_RESULT_FILE=""

            if [ "$RESULT" = "DELAY" ]; then
                DELAY_COUNT=$((DELAY_COUNT + 1))
                echo "[$(date +%H:%M)] User clicked Delay ($DELAY_COUNT/$MAX_DELAYS)."
                TIMER=900  # 15 min
            else
                # Timeout, Manual Lock, or Window Closed
                echo "[$(date +%H:%M)] Blocking screen for break."
                python3 "$SCRIPT_DIR/autodoro_blocker.py"
                _on_session_end
                TIMER=$WORK_TIME
            fi
            ZENITY_PID=""
        elif [ $TIMER -le 0 ]; then
            # Failsafe: Timer hit zero but popup is still hanging
            echo "[$(date +%H:%M)] Time expired. Blocking screen for break."
            kill $ZENITY_PID 2>/dev/null
            rm -f "$POPUP_RESULT_FILE"
            POPUP_RESULT_FILE=""
            python3 "$SCRIPT_DIR/autodoro_blocker.py"
            _on_session_end
            TIMER=$WORK_TIME
            ZENITY_PID=""
        fi
    fi

    # 5. SINGLE DECREMENT & SLEEP
    # We sleep first to ensure the first iteration doesn't immediately lose 5s
    sleep $CHECK_INTERVAL
    # Reset countdown if user has been idle longer than IDLE_PAUSE_SECS.
    # Returning after a long break should give a fresh work cycle.
    IDLE_MS=$(xprintidle 2>/dev/null || echo 0)
    if [ "$IDLE_MS" -ge $((IDLE_PAUSE_SECS * 1000)) ]; then
        if [ "$WAS_IDLE" != true ]; then
            echo "[$(date +%H:%M)] Idle ${IDLE_PAUSE_SECS}s+. Resetting timer."
            WAS_IDLE=true
        fi
        TIMER=$WORK_TIME
        DELAY_COUNT=0
        if [ -n "$ZENITY_PID" ]; then
            kill $ZENITY_PID 2>/dev/null
            ZENITY_PID=""
            [[ -n $POPUP_RESULT_FILE ]] && rm -f "$POPUP_RESULT_FILE"
            POPUP_RESULT_FILE=""
        fi
    else
        WAS_IDLE=false
        TIMER=$((TIMER - CHECK_INTERVAL))
    fi

    # Final safety clamp
    if [ $TIMER -lt 0 ]; then TIMER=0; fi
done
