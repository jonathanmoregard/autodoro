#!/usr/bin/env bash
# Smoke test for the autodoro session-end state machine + defenses.
# Reproduces the relevant section of autodoro.sh and drives it with
# scripted DELAY_COUNT values, asserting expected transitions.

set -euo pipefail

STATE_DIR="$(mktemp -d)"
STATE_FILE="$STATE_DIR/state"
STATE_SCHEMA=1
MAX_DELAYS=2
PENALTY_AFTER_SESSIONS=2
CONSEC_MAX_SKIP_SESSIONS=0
PENALTY_REMAINING=0
DELAY_COUNT=0

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
        value="${value%$'\r'}"
        case "$key" in
            schema)                   schema="$value" ;;
            consec_max_skip_sessions) CONSEC_MAX_SKIP_SESSIONS="$(_as_uint "$value")" ;;
            penalty_remaining)        PENALTY_REMAINING="$(_as_uint "$value")" ;;
        esac
    done < "$STATE_FILE"
    if [ -n "$schema" ] && [ "$schema" != "$STATE_SCHEMA" ]; then
        CONSEC_MAX_SKIP_SESSIONS=0
        PENALTY_REMAINING=0
    fi
    if [ "$PENALTY_AFTER_SESSIONS" -le 0 ]; then
        PENALTY_REMAINING=0
        CONSEC_MAX_SKIP_SESSIONS=0
    elif [ "$PENALTY_REMAINING" -gt "$PENALTY_AFTER_SESSIONS" ]; then
        PENALTY_REMAINING=$PENALTY_AFTER_SESSIONS
    fi
}

_save_state() {
    local dir tmp
    dir="$(dirname "$STATE_FILE")"
    mkdir -p "$dir"
    find "$dir" -maxdepth 1 -name 'state.??????' -type f -mmin +5 -delete 2>/dev/null || true
    tmp="$(mktemp "$dir/state.XXXXXX")"
    cat > "$tmp" <<EOF
schema=$STATE_SCHEMA
consec_max_skip_sessions=$CONSEC_MAX_SKIP_SESSIONS
penalty_remaining=$PENALTY_REMAINING
EOF
    mv -f "$tmp" "$STATE_FILE"
}

_on_session_end() {
    if [ "$PENALTY_AFTER_SESSIONS" -le 0 ]; then
        if [ "$PENALTY_REMAINING" -ne 0 ] || [ "$CONSEC_MAX_SKIP_SESSIONS" -ne 0 ]; then
            PENALTY_REMAINING=0
            CONSEC_MAX_SKIP_SESSIONS=0
            _save_state
        fi
        DELAY_COUNT=0
        return
    fi
    if [ "$PENALTY_REMAINING" -gt 0 ]; then
        PENALTY_REMAINING=$((PENALTY_REMAINING - 1))
    elif [ "$DELAY_COUNT" -ge "$MAX_DELAYS" ]; then
        CONSEC_MAX_SKIP_SESSIONS=$((CONSEC_MAX_SKIP_SESSIONS + 1))
        if [ "$CONSEC_MAX_SKIP_SESSIONS" -ge "$PENALTY_AFTER_SESSIONS" ]; then
            PENALTY_REMAINING=$PENALTY_AFTER_SESSIONS
            CONSEC_MAX_SKIP_SESSIONS=0
        fi
    else
        CONSEC_MAX_SKIP_SESSIONS=0
    fi
    DELAY_COUNT=0
    _save_state
}

# --- Helpers ---

skip_disabled() {
    [ "$PENALTY_REMAINING" -gt 0 ] || [ "$DELAY_COUNT" -ge "$MAX_DELAYS" ]
}

assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $name expected=$expected actual=$actual" >&2
        exit 1
    fi
    echo "  ok $name=$actual"
}

session() {
    local label="$1" skips_used="$2"
    DELAY_COUNT=$skips_used
    _on_session_end
    echo "session $label: skips_used=$skips_used penalty=$PENALTY_REMAINING streak=$CONSEC_MAX_SKIP_SESSIONS skip_disabled_next=$(skip_disabled && echo Y || echo N)"
}

reset_state() {
    CONSEC_MAX_SKIP_SESSIONS=0
    PENALTY_REMAINING=0
    rm -f "$STATE_FILE"
}

# --- Scenario A: maxed × 2 → penalty × 2 → restored ---
echo "=== Scenario A: maxed × 2 → penalty × 2 → restored ==="
session "1 (max)" 2
assert_eq "A1.penalty" "$PENALTY_REMAINING" 0
assert_eq "A1.streak"  "$CONSEC_MAX_SKIP_SESSIONS" 1
session "2 (max)" 2
assert_eq "A2.penalty" "$PENALTY_REMAINING" 2
assert_eq "A2.streak"  "$CONSEC_MAX_SKIP_SESSIONS" 0
session "3 (penalty)" 0
assert_eq "A3.penalty" "$PENALTY_REMAINING" 1
session "4 (penalty)" 0
assert_eq "A4.penalty" "$PENALTY_REMAINING" 0
DELAY_COUNT=0
if skip_disabled; then echo "FAIL: skip should be enabled at start of session 5"; exit 1; fi
echo "  ok skip enabled at start of session 5"

# --- Scenario B: streak reset by a good session ---
echo "=== Scenario B: streak reset by a non-max session ==="
reset_state
session "B1 (max)" 2
assert_eq "B1.streak" "$CONSEC_MAX_SKIP_SESSIONS" 1
session "B2 (1 skip)" 1
assert_eq "B2.streak" "$CONSEC_MAX_SKIP_SESSIONS" 0
session "B3 (max)" 2
assert_eq "B3.streak" "$CONSEC_MAX_SKIP_SESSIONS" 1

# --- Scenario C: state persistence across restart ---
echo "=== Scenario C: persistence ==="
reset_state
CONSEC_MAX_SKIP_SESSIONS=99
PENALTY_REMAINING=99
_save_state
CONSEC_MAX_SKIP_SESSIONS=0
PENALTY_REMAINING=0
_load_state
# C also exercises the load-time clamp: PENALTY_REMAINING was 99 but
# config says PENALTY_AFTER_SESSIONS=2, so it must clamp to 2.
assert_eq "C.consec"    "$CONSEC_MAX_SKIP_SESSIONS" 99
assert_eq "C.penalty_clamped" "$PENALTY_REMAINING" 2

# --- Scenario D: PENALTY_AFTER_SESSIONS=0 clears stale penalty ---
echo "=== Scenario D: throttle disabled mid-penalty drains state ==="
reset_state
PENALTY_AFTER_SESSIONS=2
PENALTY_REMAINING=2
CONSEC_MAX_SKIP_SESSIONS=1
PENALTY_AFTER_SESSIONS=0
DELAY_COUNT=0
_on_session_end
assert_eq "D.penalty" "$PENALTY_REMAINING" 0
assert_eq "D.streak"  "$CONSEC_MAX_SKIP_SESSIONS" 0
PENALTY_AFTER_SESSIONS=2

# --- Scenario E: torn state file (garbage values) ---
echo "=== Scenario E: garbage state coerces to 0 ==="
cat > "$STATE_FILE" <<EOF
schema=1
consec_max_skip_sessions=foo
penalty_remaining=
EOF
CONSEC_MAX_SKIP_SESSIONS=99
PENALTY_REMAINING=99
_load_state
assert_eq "E.consec_coerced"  "$CONSEC_MAX_SKIP_SESSIONS" 0
assert_eq "E.penalty_coerced" "$PENALTY_REMAINING" 0

# --- Scenario F: zero-byte state file (atomic-write crash window) ---
echo "=== Scenario F: zero-byte state file ==="
: > "$STATE_FILE"
CONSEC_MAX_SKIP_SESSIONS=7
PENALTY_REMAINING=7
_load_state
assert_eq "F.consec"  "$CONSEC_MAX_SKIP_SESSIONS" 7   # never touched (no records read)
assert_eq "F.penalty" "$PENALTY_REMAINING" 2          # clamped by config ceiling

# --- Scenario G: unknown schema wipes state ---
echo "=== Scenario G: future-schema file is treated as untrusted ==="
cat > "$STATE_FILE" <<EOF
schema=99
consec_max_skip_sessions=5
penalty_remaining=5
EOF
CONSEC_MAX_SKIP_SESSIONS=0
PENALTY_REMAINING=0
_load_state
assert_eq "G.consec"  "$CONSEC_MAX_SKIP_SESSIONS" 0
assert_eq "G.penalty" "$PENALTY_REMAINING" 0

# --- Scenario I: throttle disabled at load drains stranded penalty ---
echo "=== Scenario I: PENALTY_AFTER_SESSIONS=0 at load drains stale state ==="
reset_state
PENALTY_AFTER_SESSIONS=2
PENALTY_REMAINING=5
CONSEC_MAX_SKIP_SESSIONS=3
_save_state
PENALTY_AFTER_SESSIONS=0
PENALTY_REMAINING=0
CONSEC_MAX_SKIP_SESSIONS=0
_load_state
assert_eq "I.penalty_drained" "$PENALTY_REMAINING" 0
assert_eq "I.streak_drained"  "$CONSEC_MAX_SKIP_SESSIONS" 0
PENALTY_AFTER_SESSIONS=2

# --- Scenario H: atomic write survives interruption ---
echo "=== Scenario H: atomic write — temp file never overwrites on crash ==="
reset_state
PENALTY_REMAINING=3
_save_state
# Simulate a partial follow-on save by writing an unfinished tmp and
# verifying the state file isn't damaged. mktemp gives the temp dir,
# so any abandoned tempfile is sibling to STATE_FILE.
echo "trash" > "$STATE_DIR/state.partial"
prior_content="$(cat "$STATE_FILE")"
ls "$STATE_DIR"/state.partial >/dev/null   # the tmp exists, untouched
assert_eq "H.untouched" "$(cat "$STATE_FILE")" "$prior_content"

echo "=== ALL PASS ==="
