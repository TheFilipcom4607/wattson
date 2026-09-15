#!/bin/bash
# Saves everything Wattson can say about this machine, so a macOS upgrade can be
# checked against it afterwards.
#
#   ./snapshot.sh before-27            # write probes/snapshot-before-27-<time>/
#   ./snapshot.sh after-27
#   ./snapshot.sh --compare probes/snapshot-before-27-* probes/snapshot-after-27-*
#
# Take both with the same things plugged in: most readings are legitimately
# empty with nothing attached, and the comparison is only meaningful like for
# like. Snapshots land in probes/, which is gitignored — they carry serials.
set -uo pipefail
cd "$(dirname "$0")"

BIN=".build/debug/Wattson"

# No `timeout` on macOS. A reader that hangs on a new OS is itself a finding,
# and must not stop the rest of the snapshot being written.
limit() {
    local seconds=$1; shift
    if command -v perl >/dev/null; then
        perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    else
        "$@"
    fi
}

# Only the changed lines, or "(same)". Decided on the output rather than on
# exit codes: under pipefail, diff's own "files differ" status would win.
changes() {
    local out
    out=$(diff "$1" "$2" | grep '^[<>]')
    if [[ -n "$out" ]]; then echo "$out"; else echo "(same)"; fi
}

compare() {
    local a=${1%/} b=${2%/}
    for d in "$a" "$b"; do
        [[ -d "$d" ]] || { echo "not a snapshot directory: $d" >&2; exit 1; }
    done
    echo "Comparing"
    echo "  before: $a"
    echo "  after:  $b"

    echo; echo "=== SYSTEM ==="
    changes "$a/system.txt" "$b/system.txt"

    echo; echo "=== BUILD, SELFTEST AND EXIT CODES ==="
    changes "$a/status.txt" "$b/status.txt"
    grep -h 'checks passed' "$a/selftest.txt" "$b/selftest.txt" 2>/dev/null
    grep -h '^FAILED' "$b/selftest.txt" 2>/dev/null

    echo; echo "=== HEALTH (a line here is a source that changed) ==="
    changes <(sed -n '/^[a-z]/,$p' "$a/health.txt") <(sed -n '/^[a-z]/,$p' "$b/health.txt")

    echo; echo "=== JSON FIELDS PRESENT (< only before, > only after) ==="
    if command -v jq >/dev/null; then
        local paths='[paths(scalars) | map(if type == "number" then "[]" else . end) | join(".")] | unique | .[]'
        changes <(jq -r "$paths" "$a/reading.json" 2>/dev/null) <(jq -r "$paths" "$b/reading.json" 2>/dev/null)
    else
        echo "(jq not installed; skipped)"
    fi

    echo; echo "=== RAW CAPTURE: SECTIONS AND EMPTY SOURCES ==="
    local ca cb
    ca=$(ls "$a"/Wattson-*.txt 2>/dev/null | head -1)
    cb=$(ls "$b"/Wattson-*.txt 2>/dev/null | head -1)
    if [[ -n "$ca" && -n "$cb" ]]; then
        # Section headers, each section that came back empty, and the SMC keys
        # that stopped answering.
        summarise() {
            awk '/^=== /{h=$0; next} h && /^<(no output|could not|AppleSMC)/{print h" -> "$0; h=""} /=<not available>/{print "SMC " $0}' "$1"
            grep '^=== ' "$1"
        }
        changes <(summarise "$ca" | sort -u) <(summarise "$cb" | sort -u)
    else
        echo "(a raw capture is missing from one side)"
    fi

    echo; echo "=== APP LAUNCH ==="
    changes "$a/launch.txt" "$b/launch.txt"

    echo; echo "=== DUMP, WITH NUMBERS MASKED ==="
    changes <(sed -E 's/[0-9]+(\.[0-9]+)?/#/g' "$a/dump.txt") <(sed -E 's/[0-9]+(\.[0-9]+)?/#/g' "$b/dump.txt")
}

if [[ "${1:-}" == "--compare" ]]; then
    [[ $# -eq 3 ]] || { echo "usage: $0 --compare <before-dir> <after-dir>" >&2; exit 1; }
    compare "$2" "$3"
    exit 0
fi

LABEL=$(echo "${1:-snapshot}" | tr -c 'A-Za-z0-9._-' '-' | sed 's/-*$//')
STAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
OUT="probes/snapshot-${LABEL}-${STAMP}"
mkdir -p "$OUT"
: > "$OUT/status.txt"
status() { echo "$1: $2" >> "$OUT/status.txt"; }

echo "==> Writing $OUT"

{
    sw_vers
    uname -rm
    sysctl -n hw.model
    xcode-select -p 2>&1
    pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | grep '^version'
    swift --version 2>&1 | head -1
} > "$OUT/system.txt"

# Whether it still compiles against the new SDK is the first thing an upgrade
# can break. A failed build falls back to whatever binary is already there, so
# the hardware readings are still taken.
echo "==> Building"
if swift build > "$OUT/build.log" 2>&1; then
    status build ok
else
    status build FAILED
    echo "    build failed; see $OUT/build.log"
fi
if [[ ! -x "$BIN" ]]; then
    echo "    no binary to run; only system.txt and build.log were written"
    exit 1
fi

run() {
    local name=$1 file=$2 seconds=$3; shift 3
    echo "==> $name"
    limit "$seconds" "$BIN" "$@" > "$OUT/$file" 2>&1
    status "$name" "exit $?"
}
run selftest selftest.txt 60 --selftest
run health   health.txt   120 --health
run dump     dump.txt     120 --dump
run json     reading.json 120 --json

echo "==> raw capture"
(cd "$OUT" && limit 600 "../../$BIN" --capture "$LABEL" > capture-path.txt 2>&1)
status capture "exit $?"

# The GUI is the part none of the CLI modes exercise. Launches the installed
# app only if it is not already running, and does not stop it afterwards.
echo "==> App launch"
{
    APP="/Applications/Wattson.app"
    if pgrep -x Wattson >/dev/null; then
        echo "running: yes (was already running)"
    elif [[ -d "$APP" ]]; then
        open -g "$APP"
        sleep 6
        pgrep -x Wattson >/dev/null && echo "running: yes (launched)" || echo "running: NO (launched, then gone)"
    else
        echo "running: not installed"
    fi
    [[ -d "$APP" ]] && codesign --verify "$APP" 2>&1 && echo "signature: valid"
} > "$OUT/launch.txt" 2>&1
# Copied rather than listed: report names carry timestamps and would show up in
# every comparison. Only reports from the last day, so old ones don't pile in.
find ~/Library/Logs/DiagnosticReports -maxdepth 1 -iname 'Wattson*' -mtime -1 \
    -exec cp {} "$OUT/" \; 2>/dev/null

echo
cat "$OUT/status.txt"
echo
echo "Saved to $OUT"
