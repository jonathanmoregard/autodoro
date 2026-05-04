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
            mic_exclude)         MIC_EXCLUDE_PATTERNS+=("$value") ;;
        esac
    done < "$file"
}
_load_config "$SCRIPT_DIR/config.defaults"
_load_config "${XDG_CONFIG_HOME:-$HOME/.config}/autodoro/config"

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
    # After MAX_DELAYS consecutive delays, show popup with Delay button permanently disabled.
    if [ $TIMER -le $WARNING_THRESHOLD ] && [ -z "$ZENITY_PID" ]; then
        if [ $DELAY_COUNT -ge $MAX_DELAYS ]; then
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
                TIMER=$WORK_TIME
                DELAY_COUNT=0
            fi
            ZENITY_PID=""
        elif [ $TIMER -le 0 ]; then
            # Failsafe: Timer hit zero but popup is still hanging
            echo "[$(date +%H:%M)] Time expired. Blocking screen for break."
            kill $ZENITY_PID 2>/dev/null
            rm -f "$POPUP_RESULT_FILE"
            POPUP_RESULT_FILE=""
            python3 "$SCRIPT_DIR/autodoro_blocker.py"
            TIMER=$WORK_TIME
            DELAY_COUNT=0
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
