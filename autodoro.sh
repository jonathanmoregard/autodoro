#!/bin/bash

# --- CONFIGURATION DEFAULTS ---
# These are overridden by config.defaults, then by ~/.config/autodoro/config.
WORK_TIME=1500
POST_MEETING_TIME=900
WARNING_THRESHOLD=60
CHECK_INTERVAL=5
DELAY_UNLOCK_SECS=3
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
            mic_exclude)         MIC_EXCLUDE_PATTERNS+=("$value") ;;
        esac
    done < "$file"
}
_load_config "$SCRIPT_DIR/config.defaults"
_load_config "${XDG_CONFIG_HOME:-$HOME/.config}/autodoro/config"

WAS_IN_MEETING=false
WAS_LOCKED=false
ZENITY_PID=""
POPUP_RESULT_FILE=""
TIMER=$WORK_TIME

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
    # Resolve excluded PIDs from configured pgrep patterns, then check source-outputs.
    _EXCLUDED_PIDS=""
    for _pat in "${MIC_EXCLUDE_PATTERNS[@]}"; do
        _EXCLUDED_PIDS="$_EXCLUDED_PIDS $(pgrep -f "$_pat" 2>/dev/null | tr '\n' ' ')"
    done

    _PW_DUMP=$(pw-dump 2>/dev/null)
    MIC_IN_USE=$(AUTODORO_EXCLUDED_PIDS="$_EXCLUDED_PIDS" AUTODORO_PW_DUMP="$_PW_DUMP" pactl list source-outputs 2>/dev/null | python3 -c "
import sys, os, json
excluded = set(os.environ.get('AUTODORO_EXCLUDED_PIDS', '').split())
# Build name -> sec.pid map from pw-dump Client objects (needed for ALSA-bridge
# clients, which omit application.process.id in pactl but carry real PID as
# pipewire.sec.pid in pw-dump).
name_to_secpid = {}
try:
    for obj in json.loads(os.environ.get('AUTODORO_PW_DUMP', '[]') or '[]'):
        if obj.get('type') == 'PipeWire:Interface:Client':
            props = obj.get('info', {}).get('props', {})
            nm = props.get('application.name')
            sp = props.get('pipewire.sec.pid')
            if nm and sp is not None:
                name_to_secpid[nm] = str(sp)
except Exception:
    pass
text = sys.stdin.read()
for block in text.split('\n\n'):
    name = pid = None
    for line in block.split('\n'):
        s = line.strip()
        if s.startswith('application.name = '): name = s.split('= ', 1)[1].strip('\"')
        elif s.startswith('application.process.id = '): pid = s.split('= ', 1)[1].strip('\"')
    effective_pid = pid or name_to_secpid.get(name)
    if name and name != 'cinnamon' and effective_pid not in excluded:
        print('yes|' + str(name) + '|' + str(effective_pid)); break
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
    # Only trigger if timer is low AND no popup is already active
    if [ $TIMER -le $WARNING_THRESHOLD ] && [ -z "$ZENITY_PID" ]; then
        echo "[$(date +%H:%M)] Triggering warning (Time remaining: ${TIMER}s)."
        POPUP_RESULT_FILE=$(mktemp)
        CAPTURED_TIMER=$TIMER

        (
            python3 "$SCRIPT_DIR/autodoro_popup.py" "$CAPTURED_TIMER" "$DELAY_UNLOCK_SECS"
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
                echo "[$(date +%H:%M)] User clicked Delay."
                TIMER=900  # 15 min
            else
                # Timeout, Manual Lock, or Window Closed
                echo "[$(date +%H:%M)] Blocking screen for break."
                python3 "$SCRIPT_DIR/autodoro_blocker.py"
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
            TIMER=$WORK_TIME
            ZENITY_PID=""
        fi
    fi

    # 5. SINGLE DECREMENT & SLEEP
    # We sleep first to ensure the first iteration doesn't immediately lose 5s
    sleep $CHECK_INTERVAL
    TIMER=$((TIMER - CHECK_INTERVAL))

    # Final safety clamp
    if [ $TIMER -lt 0 ]; then TIMER=0; fi
done
