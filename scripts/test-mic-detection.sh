#!/usr/bin/env bash
# Test for meeting detection and mic_exclude filtering.
#
# Unlike test-state-machine.sh, this does NOT reimplement the logic —
# it extracts the real block from autodoro.sh between the
# BEGIN/END mic-detection markers and runs it against a stubbed
# `pactl`. A copy would not have caught the original bug here: the
# excludes were passed as a command-prefix env assignment
# (`AUTODORO_EXCLUDES=... pactl ... | python3`), which binds only to
# `pactl` and never reaches `python3` on the other side of the pipe,
# so every mic_exclude pattern was silently ignored.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Extract the block under test ---
SNIPPET="$TMP/detect.sh"
awk '/# --- BEGIN mic-detection ---/{f=1;next} /# --- END mic-detection ---/{f=0} f' \
    "$REPO_DIR/autodoro.sh" > "$SNIPPET"
[ -s "$SNIPPET" ] || { echo "FAIL: could not extract mic-detection block from autodoro.sh" >&2; exit 1; }

# --- Stub pactl: prints whichever fixture the current case points at ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pactl" <<'STUB'
#!/usr/bin/env bash
cat "$AUTODORO_TEST_FIXTURE"
STUB
chmod +x "$TMP/bin/pactl"
PATH="$TMP/bin:$PATH"

FIXTURE="$TMP/fixture"
export AUTODORO_TEST_FIXTURE="$FIXTURE"

# Emit a pactl-shaped source-output block. Args: name [binary] [node]
sink_block() {
    local n=1
    printf 'Source Output #%s\n\tDriver: PipeWire\n\tProperties:\n' "$n"
    printf '\t\tapplication.name = "%s"\n' "$1"
    [ -n "${2:-}" ] && printf '\t\tapplication.process.binary = "%s"\n' "$2"
    [ -n "${3:-}" ] && printf '\t\tnode.name = "%s"\n' "$3"
    printf '\n'
}

# Run the extracted block with the given excludes; echo MIC_IN_USE.
# Deliberately does NOT set AUTODORO_EXCLUDES itself — publishing the
# patterns to the environment is part of the code under test, so a
# regression back to the command-prefix form fails these assertions.
detect() {
    MIC_EXCLUDE_PATTERNS=("$@")
    unset AUTODORO_EXCLUDES
    MIC_IN_USE=""
    # set -u: bash <4.4 errors on "${arr[@]}" when arr is empty, and
    # autodoro.sh itself does not run under set -u.
    set +u
    # shellcheck disable=SC1090
    source "$SNIPPET"
    set -u
    printf '%s' "$MIC_IN_USE"
}

assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: $name expected=[$expected] actual=[$actual]" >&2
        exit 1
    fi
    echo "  ok $name=[$actual]"
}

# --- Scenario A: the regression — excluded app must not count ---
# Cinnamon's volume applet holds a mic source-output indefinitely.
# Before the fix this returned "yes|cinnamon", which pinned the timer
# in "meeting paused" for days at a time.
echo "=== Scenario A: excluded app is not a meeting ==="
sink_block "cinnamon" "cinnamon" "cinnamon" > "$FIXTURE"
assert_eq "A.cinnamon_excluded" "$(detect cinnamon)" ""

# --- Scenario B: a real meeting is still detected ---
echo "=== Scenario B: non-excluded app is a meeting ==="
sink_block "ZOOM VoiceEngine" "zoom" "zoom-input" > "$FIXTURE"
assert_eq "B.zoom_detected" "$(detect cinnamon)" "yes|ZOOM VoiceEngine"

# --- Scenario C: excluded + real stream at once → real one wins ---
echo "=== Scenario C: excluded stream does not mask a real meeting ==="
{ sink_block "cinnamon" "cinnamon" "cinnamon"
  sink_block "ZOOM VoiceEngine" "zoom" "zoom-input"; } > "$FIXTURE"
assert_eq "C.zoom_wins" "$(detect cinnamon)" "yes|ZOOM VoiceEngine"

# --- Scenario D: no mic streams at all ---
echo "=== Scenario D: no source-outputs ==="
: > "$FIXTURE"
assert_eq "D.no_streams" "$(detect cinnamon)" ""

# --- Scenario E: no excludes configured → everything counts ---
echo "=== Scenario E: empty exclude list detects everything ==="
sink_block "cinnamon" "cinnamon" "cinnamon" > "$FIXTURE"
assert_eq "E.no_excludes" "$(detect)" "yes|cinnamon"

# --- Scenario F: matching is case-insensitive ---
echo "=== Scenario F: case-insensitive match ==="
sink_block "Cinnamon" "cinnamon" "cinnamon" > "$FIXTURE"
assert_eq "F.case_insensitive" "$(detect CINNAMON)" ""

# --- Scenario G: match via application.process.binary, not just name ---
echo "=== Scenario G: exclude matches on process binary ==="
sink_block "WhisperWriter" "whisper-writer" "capture-1" > "$FIXTURE"
assert_eq "G.binary_match" "$(detect whisper-writer)" ""

# --- Scenario H: match via node.name ---
echo "=== Scenario H: exclude matches on node.name ==="
sink_block "SomeApp" "someapp" "alsa_input.monitor-probe" > "$FIXTURE"
assert_eq "H.node_match" "$(detect monitor-probe)" ""

# --- Scenario I: multiple exclude patterns ---
echo "=== Scenario I: multiple exclude patterns ==="
{ sink_block "cinnamon" "cinnamon" "cinnamon"
  sink_block "WhisperWriter" "whisper-writer" "capture-1"; } > "$FIXTURE"
assert_eq "I.multi_exclude" "$(detect cinnamon whisper-writer)" ""

echo "=== ALL PASS ==="
