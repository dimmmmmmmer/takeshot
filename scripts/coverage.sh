#!/bin/bash
# Measure line coverage, write the lcov report, and hold it above the floor.
#
# One implementation for CI and for the machine you develop on, so the number
# cannot differ between them. The floor itself lives in `.coverage-floor` and
# nowhere else.
#
#   scripts/coverage.sh                 run the suite, export lcov, check the floor
#   scripts/coverage.sh --report-only   skip the run, use the profdata already there
#   scripts/coverage.sh --floor 90      override the floor for one run
#   scripts/coverage.sh --top 20        how many files to list (default 12)
#
# --no-parallel is not optional: the suites' contract is serial execution (the
# view tests share UserDefaults.standard through @AppStorage, and parallel runs
# raced each other's keys). `scripts/test.sh` passes it, which is why the run
# goes through that script rather than calling `swift test` here.
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR_FILE=".coverage-floor"
LCOV_OUT="coverage.lcov"
REPORT_OUT="coverage-report.txt"
RUN_TESTS=1
TOP=12
FLOOR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --report-only) RUN_TESTS=0; shift ;;
        --floor) FLOOR="$2"; shift 2 ;;
        --top) TOP="$2"; shift 2 ;;
        *) echo "coverage.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

if [ -z "$FLOOR" ]; then
    if [ ! -f "$FLOOR_FILE" ]; then
        echo "coverage.sh: $FLOOR_FILE is missing — the floor has to be stated" >&2
        exit 2
    fi
    # the file carries a comment block explaining itself; the number is the
    # last non-comment, non-blank line
    FLOOR=$(grep -v '^[[:space:]]*#' "$FLOOR_FILE" | grep -v '^[[:space:]]*$' \
            | tail -1 | tr -d '[:space:]')
fi
case "$FLOOR" in
    ''|*[!0-9.]*) echo "coverage.sh: '$FLOOR' is not a percentage" >&2; exit 2 ;;
esac

if [ "$RUN_TESTS" -eq 1 ]; then
    echo "==> running the suite with coverage"
    scripts/test.sh --enable-code-coverage
fi

BIN=$(swift build --enable-code-coverage --show-bin-path)
PROF="$BIN/codecov/default.profdata"
if [ ! -f "$PROF" ]; then
    echo "coverage.sh: no profdata at $PROF — run without --report-only" >&2
    exit 2
fi

# Every test bundle counts: the first is positional, the rest are -object,
# otherwise a second test target drops out of the report.
OBJECTS=()
while IFS= read -r XCTEST; do
    BINARY="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
    if [ ${#OBJECTS[@]} -eq 0 ]; then
        OBJECTS+=("$BINARY")
    else
        OBJECTS+=(-object "$BINARY")
    fi
done < <(find "$BIN" -name '*.xctest' -maxdepth 2)
if [ ${#OBJECTS[@]} -eq 0 ]; then
    echo "coverage.sh: found no test bundles under $BIN" >&2
    exit 2
fi
echo "==> test bundles: ${#OBJECTS[@]}"

IGNORE='(Tests|\.build)/'
xcrun llvm-cov export "${OBJECTS[@]}" -instr-profile "$PROF" \
    -format=lcov -ignore-filename-regex="$IGNORE" > "$LCOV_OUT"
xcrun llvm-cov report "${OBJECTS[@]}" -instr-profile "$PROF" \
    -ignore-filename-regex="$IGNORE" > "$REPORT_OUT"
echo "==> $LCOV_OUT ($(wc -l < "$LCOV_OUT") lines), $REPORT_OUT"

# llvm-cov's own TOTAL row: columns are lines, missed lines, cover.
read -r TOTAL_LINES MISSED_LINES ACTUAL < <(
    awk '$1 == "TOTAL" { gsub("%", "", $10); print $8, $9, $10 }' "$REPORT_OUT")
if [ -z "${ACTUAL:-}" ]; then
    echo "coverage.sh: could not read a TOTAL row out of $REPORT_OUT" >&2
    exit 2
fi

echo
echo "line coverage: ${ACTUAL}%  (${MISSED_LINES} of ${TOTAL_LINES} lines uncovered)"
echo "floor:         ${FLOOR}%"

if awk -v a="$ACTUAL" -v f="$FLOOR" 'BEGIN { exit !(a + 0 >= f + 0) }'; then
    echo "PASS: coverage is at or above the floor."
    exit 0
fi

# Below the floor. Say by how much, and say WHERE the uncovered lines are — a
# drop is nearly always new code, and new code lands at the top of this list.
SHORT=$(awk -v a="$ACTUAL" -v f="$FLOOR" 'BEGIN { printf "%.2f", f - a }')
cat >&2 <<EOF

FAIL: line coverage ${ACTUAL}% is ${SHORT} points below the ${FLOOR}% floor
      (${MISSED_LINES} of ${TOTAL_LINES} lines uncovered).

The floor is stated in ${FLOOR_FILE}. Either cover the new lines or, if the
drop is deliberate and understood, move the floor and say why in the commit.

Files holding the most uncovered lines (missed / total / covered):
EOF
awk 'NR > 2 && $1 ~ /\.swift$/ { printf "  %6d  %6d  %7s  %s\n", $9, $8, $10, $1 }' \
    "$REPORT_OUT" | sort -rn | head -"$TOP" >&2
exit 1
