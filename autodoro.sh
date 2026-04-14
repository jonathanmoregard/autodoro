#!/bin/bash

# --- CONFIGURATION ---
WORK_TIME=1500           # 25 min
POST_MEETING_TIME=900   # 15 min
WARNING_THRESHOLD=60    # 1 min
CHECK_INTERVAL=5
DELAY_UNLOCK_SECS=3     # seconds before delay button unlocks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMER=$WORK_TIME
WAS_IN_MEETING=false
WAS_LOCKED=false
ZENITY_PID=""
POPUP_RESULT_FILE=""

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
        [[ -n $ZENITY_PID ]] && kill $ZENITY_PID 2>/dev/null && ZENITY_PID=""
        [[ -n $POPUP_RESULT_FILE ]] && rm -f "$POPUP_RESULT_FILE" && POPUP_RESULT_FILE=""
    fi

    # 1. MEETING DETECTION
    if pactl list source-outputs 2>/dev/null | grep -v 'application.name = "cinnamon"' | grep -q 'application.name'; then
        if [ "$WAS_IN_MEETING" = false ]; then
            echo "[$(date +%H:%M)] Meeting detected. Timer paused."
            WAS_IN_MEETING=true
            # Kill popup if it was open when meeting started
            [[ -n $ZENITY_PID ]] && kill $ZENITY_PID 2>/dev/null && ZENITY_PID=""
            [[ -n $POPUP_RESULT_FILE ]] && rm -f "$POPUP_RESULT_FILE" && POPUP_RESULT_FILE=""
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
