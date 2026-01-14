#!/bin/bash

# --- CONFIGURATION ---
WORK_TIME=1500           # 25 min
POST_MEETING_TIME=900   # 15 min
WARNING_THRESHOLD=60    # 1 min
CHECK_INTERVAL=5        

TIMER=$WORK_TIME
WAS_IN_MEETING=false
ZENITY_PID=""

echo "[$(date +%H:%M)] Autodoro: Monitoring mic via PipeWire/PulseAudio..."

while true; do
    # 0. LOCK DETECTION (Cinnamon-specific)
    # If the screensaver is active, don't count down, don't trigger popups.
    if cinnamon-screensaver-command -q 2>/dev/null | grep -q "is active"; then
        sleep $CHECK_INTERVAL
        continue
    fi

    # 1. MEETING DETECTION
    if pactl list short source-outputs | grep -q '^[0-9]'; then
        if [ "$WAS_IN_MEETING" = false ]; then
            echo "[$(date +%H:%M)] Meeting detected. Timer paused."
            WAS_IN_MEETING=true
            # Kill popup if it was open when meeting started
            [[ -n $ZENITY_PID ]] && kill $ZENITY_PID 2>/dev/null && ZENITY_PID=""
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
        
        zenity --question --title="Autodoro" \
               --text="Time's almost up! Computer will auto-lock in $TIMER seconds." \
               --ok-label="Delay 25m" --cancel-label="Lock Now" --timeout=$TIMER &
        
        ZENITY_PID=$!
    fi

    # 4. MONITOR POPUP RESPONSE
    if [ -n "$ZENITY_PID" ]; then
        if ! ps -p $ZENITY_PID > /dev/null; then
            # Zenity process finished; wait for it to get the exit code
            wait $ZENITY_PID
            EXIT_CODE=$?
            
            if [ $EXIT_CODE -eq 0 ]; then
                echo "[$(date +%H:%M)] User clicked Delay."
                TIMER=1500  # 25 min
            else
                # Timeout (5), Manual Lock (1), or Window Closed
                echo "[$(date +%H:%M)] Locking session."
                cinnamon-screensaver-command -l
                sleep 2  # Small buffer for Cinnamon to register the lock
                TIMER=$WORK_TIME
            fi
            ZENITY_PID=""
        elif [ $TIMER -le 0 ]; then
            # Failsafe: Timer hit zero but popup is still hanging
            echo "[$(date +%H:%M)] Time expired. Automatic lock."
            kill $ZENITY_PID 2>/dev/null
            cinnamon-screensaver-command -l
            sleep 2  # Small buffer for Cinnamon to register the lock
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