#!/usr/bin/env bash
# Test for the meeting pause state machine and its duration cap.
#
# Like test-mic-detection.sh, this extracts the real block from
# autodoro.sh between the BEGIN/END meeting-state markers rather than
# reimplementing it, and drives it with a stubbed clock so a 3h pause
# takes no wall time. Each call to step() runs exactly one iteration of
# the main loop's meeting section.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SNIPPET="$TMP/meeting.sh"
awk '/# --- BEGIN meeting-state ---/{f=1;next} /# --- END meeting-state ---/{f=0} f' \
    "$REPO_DIR/autodoro.sh" > "$SNIPPET"
[ -s "$SNIPPET" ] || { echo "FAIL: could not extract meeting-state block from autodoro.sh" >&2; exit 1; }

# Stub clock. The block calls `date +%s` for the meeting start stamp and
# for the elapsed-time comparison; `date +%H:%M` for log lines.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/date" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    +%s) echo "$AUTODORO_TEST_NOW" ;;
    *)   echo "00:00" ;;
esac
STUB
chmod +x "$TMP/bin/date"
PATH="$TMP/bin:$PATH"
export AUTODORO_TEST_NOW=0

# --- Loop-body context the block expects ---
WORK_TIME=1500
POST_MEETING_TIME=900
CHECK_INTERVAL=5
MAX_MEETING_PAUSE_SECS=10800     # 3h
ZENITY_PID=""
POPUP_RESULT_FILE=""
TIMER=$WORK_TIME
WAS_IN_MEETING=false
MEETING_START_TS=0
MEETING_CAPPED=false

sleep() { :; }                   # never actually wait in tests

# Run one loop iteration. Args: <mic value> <now, epoch secs>
# Sets PAUSED=true if the block hit `continue` (timer frozen), false if
# execution fell through to the rest of the loop (timer runs).
step() {
    MIC_IN_USE="$1"
    AUTODORO_TEST_NOW="$2"
    PAUSED=true
    # autodoro.sh does not run under set -e/-u, and the block ends in a
    # `continue`, so wrap it in a single-pass loop with those off.
    set +eu
    for _ in 1; do
        # shellcheck disable=SC1090
        source "$SNIPPET"
        PAUSED=false
    done
    set -eu
}

mic()   { echo "yes|ZOOM VoiceEngine"; }
quiet() { echo ""; }

assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $name expected=[$expected] actual=[$actual]" >&2
        exit 1
    fi
    echo "  ok $name=[$actual]"
}

reset() {
    TIMER=$WORK_TIME
    WAS_IN_MEETING=false
    MEETING_START_TS=0
    MEETING_CAPPED=false
    MAX_MEETING_PAUSE_SECS=10800
}

# --- Scenario A: an ordinary meeting still pauses ---
echo "=== Scenario A: meeting pauses the timer ==="
reset
step "$(mic)" 0        >/dev/null
assert_eq "A.paused"      "$PAUSED"          true
assert_eq "A.in_meeting"  "$WAS_IN_MEETING"  true
assert_eq "A.start_ts"    "$MEETING_START_TS" 0
step "$(mic)" 600      >/dev/null   # 10 min in, well under the cap
assert_eq "A.still_paused" "$PAUSED"         true
assert_eq "A.timer_frozen" "$TIMER"          1500

# --- Scenario B: meeting ends normally → grace period ---
echo "=== Scenario B: meeting ends under the cap → grace period ==="
step "$(quiet)" 700    >/dev/null
assert_eq "B.fell_through" "$PAUSED"          false
assert_eq "B.grace"        "$TIMER"           900
assert_eq "B.in_meeting"   "$WAS_IN_MEETING"  false
assert_eq "B.not_capped"   "$MEETING_CAPPED"  false

# --- Scenario C: the regression guard — pause is capped at 3h ---
# This is the cinnamon-applet failure mode: a stream nobody releases.
echo "=== Scenario C: pause is capped, timer resumes with mic still held ==="
reset
step "$(mic)" 0        >/dev/null
assert_eq "C.paused_at_start" "$PAUSED" true
step "$(mic)" 10799    >/dev/null   # 1s before the cap
assert_eq "C.paused_just_under" "$PAUSED" true
step "$(mic)" 10800    >/dev/null   # cap reached exactly
assert_eq "C.fell_through_at_cap" "$PAUSED"          false
assert_eq "C.capped"              "$MEETING_CAPPED"  true
assert_eq "C.fresh_cycle"         "$TIMER"           1500
# No grace period on top of the fresh cycle.
assert_eq "C.in_meeting_cleared"  "$WAS_IN_MEETING"  false

# --- Scenario D: while capped, the mic no longer pauses anything ---
echo "=== Scenario D: capped state keeps the timer running ==="
TIMER=42
step "$(mic)" 20000    >/dev/null
assert_eq "D.still_running" "$PAUSED" false
assert_eq "D.timer_untouched" "$TIMER" 42
step "$(mic)" 99999    >/dev/null
assert_eq "D.still_running_2" "$PAUSED" false
assert_eq "D.timer_untouched_2" "$TIMER" 42

# --- Scenario E: releasing the stream re-arms the pause ---
echo "=== Scenario E: mic released → cap clears, next meeting pauses ==="
step "$(quiet)" 100000 >/dev/null
assert_eq "E.cap_cleared" "$MEETING_CAPPED" false
# No spurious grace period — the meeting had already been written off.
assert_eq "E.no_grace"    "$TIMER"          42
step "$(mic)" 100005   >/dev/null
assert_eq "E.pauses_again" "$PAUSED"           true
assert_eq "E.new_start_ts" "$MEETING_START_TS" 100005

# --- Scenario F: cap=0 disables the ceiling ---
echo "=== Scenario F: max_meeting_pause_secs=0 → unbounded pause ==="
reset
MAX_MEETING_PAUSE_SECS=0
step "$(mic)" 0        >/dev/null
step "$(mic)" 999999   >/dev/null   # ~11 days
assert_eq "F.still_paused" "$PAUSED"          true
assert_eq "F.never_capped" "$MEETING_CAPPED"  false

# --- Scenario G: a second meeting is capped on its own clock ---
echo "=== Scenario G: cap window restarts per meeting ==="
reset
step "$(mic)" 1000     >/dev/null
step "$(quiet)" 2000   >/dev/null           # short meeting, ends cleanly
step "$(mic)" 3000     >/dev/null           # new meeting starts here
assert_eq "G.new_start" "$MEETING_START_TS" 3000
step "$(mic)" 13799    >/dev/null           # 10799s into meeting two
assert_eq "G.under_cap" "$PAUSED" true
step "$(mic)" 13800    >/dev/null           # 10800s into meeting two
assert_eq "G.capped"    "$MEETING_CAPPED" true

echo "=== ALL PASS ==="
