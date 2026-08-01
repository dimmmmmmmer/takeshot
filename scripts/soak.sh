#!/bin/bash
# Flake hunter: run the test suite N times and collect every failure.
#
# The suite is green in one-off runs but has a history of going red under
# machine load, and a single red run tells you nothing once the output is
# gone. This script loops scripts/test.sh, keeps the FULL output of every
# run in .build/soak/, prints the failing test names as they happen, and
# ends with a summary of distinct failures across all runs.
#
#   scripts/soak.sh [N]        run the suite N times (default 10)
#
# Exit status is non-zero if any run failed. Logs survive in
# .build/soak/<timestamp>/run-XX.log for post-mortem.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS="${1:-10}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR=".build/soak/$STAMP"
mkdir -p "$LOG_DIR"

# Lines that mean a test (or the run) went red. Swift Testing prints
# "✘ Test ... recorded an issue" / "✘ Test ... failed after", XCTest prints
# "error:" and "failed"; the last two patterns catch crashes and build breaks.
FAIL_PATTERN='✘|recorded an issue|error:|Fatal error|Test run .* failed|failed after'

green=0
red=0
red_runs=()

for ((i = 1; i <= RUNS; i++)); do
    log="$LOG_DIR/run-$(printf '%02d' "$i").log"
    echo "=== soak run $i/$RUNS ($(date +%H:%M:%S)) → $log ==="
    start=$SECONDS
    if ./scripts/test.sh >"$log" 2>&1; then
        green=$((green + 1))
        echo "    green in $((SECONDS - start))s"
    else
        red=$((red + 1))
        red_runs+=("$i")
        echo "    RED in $((SECONDS - start))s — failure lines:"
        grep -E "$FAIL_PATTERN" "$log" | sed 's/^/    | /' || echo "    | (no failure lines matched — read the log)"
    fi
done

echo
echo "=== soak summary: $green green, $red red out of $RUNS (logs in $LOG_DIR) ==="
if [ "$red" -gt 0 ]; then
    echo "red runs: ${red_runs[*]}"
    echo "distinct failing tests:"
    # Swift Testing marks failures with "✘" on a terminal but with an SF Symbol
    # when piped, so the anchor is the phrase, not the glyph. Strip everything
    # around the test name so reruns of the same test collapse to one line.
    grep -hE 'Test .+ (recorded an issue|failed after)' "$LOG_DIR"/run-*.log \
        | grep -v 'Test run with' \
        | sed -E 's/.*Test ("[^"]*"|[A-Za-z0-9_]+\([^)]*\)).*/\1/' \
        | sort -u | sed 's/^/  /'
    exit 1
fi
