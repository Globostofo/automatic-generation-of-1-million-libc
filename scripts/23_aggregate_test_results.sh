#!/bin/bash
# =============================================================================
# Script   : 23_aggregate_test_results.sh
# Purpose  : Aggregate 20_test_variant.sh's per-variant results
#            (results/<id>.test.log + results/<id>.test.txt) across a whole
#            campaign into a single summary, instead of eyeballing thousands
#            of individual files:
#              - pass/fail count distribution across all tested variants
#                (min/max/mean/std)
#              - any variant whose ELF validity or required-ABI-symbol
#                checks themselves failed ([FAIL] lines from 20_'s sections
#                1-2) -- more serious than a functional test failure, listed
#                separately
#              - which individual libc-test executables fail most often
#                across the whole campaign (results/test_aggregate_failure_frequency.txt),
#                ranked -- a failure appearing in ~every variant is a
#                systemic/baseline issue (unrelated to what varies between
#                variants), one appearing rarely is worth investigating on
#                its own
# Usage    : ./scripts/23_aggregate_test_results.sh
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

SUMMARY="$RESULTS_DIR/test_aggregate_summary.txt"
FAILURE_FREQ="$RESULTS_DIR/test_aggregate_failure_frequency.txt"

LOGS=$(ls "$RESULTS_DIR"/*.test.log 2> /dev/null | sort)
if [ -z "$LOGS" ]; then
    echo "[ERROR] No *.test.log files found in $RESULTS_DIR -- run 20_test_variant.sh / 22_test_campaign_parallel.sh first."
    exit 1
fi

N_VARIANTS=0
ELF_ABI_ISSUES_FILE="$(mktemp)"
PASS_COUNTS_FILE="$(mktemp)"
FAIL_COUNTS_FILE="$(mktemp)"
trap 'rm -f "$ELF_ABI_ISSUES_FILE" "$PASS_COUNTS_FILE" "$FAIL_COUNTS_FILE"' EXIT

for log in $LOGS; do
    VARIANT_ID=$(basename "$log" .test.log)
    N_VARIANTS=$((N_VARIANTS + 1))

    if grep -q "^\[FAIL\]" "$log"; then
        {
            echo "$VARIANT_ID:"
            grep "^\[FAIL\]" "$log" | sed 's/^/    /'
        } >> "$ELF_ABI_ISSUES_FILE"
    fi

    PASS=$(grep "^PASS " "$log" | awk '{print $2}')
    FAIL=$(grep "^FAIL " "$log" | awk '{print $2}')
    echo "${PASS:-0}" >> "$PASS_COUNTS_FILE"
    echo "${FAIL:-0}" >> "$FAIL_COUNTS_FILE"
done

echo "=== Aggregating $N_VARIANTS variant test results ==="

PASS_STATS=$(awk '{s+=$1; sq+=$1*$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1} END{mean=s/NR; std=sqrt(sq/NR-mean*mean); printf "min=%d max=%d mean=%.2f std=%.2f", min, max, mean, std}' "$PASS_COUNTS_FILE")
FAIL_STATS=$(awk '{s+=$1; sq+=$1*$1; if(NR==1||$1<min)min=$1; if(NR==1||$1>max)max=$1} END{mean=s/NR; std=sqrt(sq/NR-mean*mean); printf "min=%d max=%d mean=%.2f std=%.2f", min, max, mean, std}' "$FAIL_COUNTS_FILE")
N_ELF_ABI_ISSUES=$(grep -c ":$" "$ELF_ABI_ISSUES_FILE" 2> /dev/null || true)

# Failure frequency across the whole campaign: how many variants each
# distinct failing test executable shows up in, ranked most-common first.
: > "$FAILURE_FREQ"
cat "$RESULTS_DIR"/*.test.txt 2> /dev/null \
    | awk '$1=="FAIL"{print $2}' \
    | sort | uniq -c | sort -rn \
    | awk -v n="$N_VARIANTS" '{printf "%-6d (%5.1f%%)  %s\n", $1, ($1/n)*100, $2}' \
    > "$FAILURE_FREQ"
N_DISTINCT_FAILURES=$(wc -l < "$FAILURE_FREQ")

{
    echo "variants tested       : $N_VARIANTS"
    echo "pass count per variant: $PASS_STATS"
    echo "fail count per variant: $FAIL_STATS"
    echo "variants w/ ELF/ABI issues (more serious than a functional fail): ${N_ELF_ABI_ISSUES:-0}"
    echo "distinct failing tests across the campaign: $N_DISTINCT_FAILURES"
    echo ""
    echo "--- ELF/ABI issues (if any) ---"
    if [ -s "$ELF_ABI_ISSUES_FILE" ]; then
        cat "$ELF_ABI_ISSUES_FILE"
    else
        echo "(none)"
    fi
} > "$SUMMARY"

echo "=== Done ==="
echo "    Summary            : $SUMMARY"
echo "    Failure frequency  : $FAILURE_FREQ"
echo ""
echo "--- Summary ---"
cat "$SUMMARY"
echo ""
echo "--- Top 10 most common failures ---"
head -10 "$FAILURE_FREQ"
