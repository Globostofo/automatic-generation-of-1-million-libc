#!/bin/bash
# =============================================================================
# Script   : 22_test_campaign_parallel.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Run tests on all musl variants
# Usage    : ./scripts/22_test_campaign_parallel.sh [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR=$(dirname "$0")
source "$SCRIPTS_DIR/config.sh"

VARIANTS=$(ls -d "$VARIANTS_DIR"/[0-9]* 2> /dev/null | sort)
if [ -z "$VARIANTS" ]
then
    echo "[ERROR] No variants found in $VARIANTS_DIR"
    exit 1
fi

if [ -z "$1" ]
then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]
then
    PARALLEL_JOBS="$1"
else
    echo "Invalid number of parallel jobs : $1"
    exit 1
fi
echo "Running on $PARALLEL_JOBS parallel jobs"

echo "=== Testing $(echo "$VARIANTS" | wc -l) variants ==="

echo "$VARIANTS" | xargs -P$PARALLEL_JOBS -I {} bash -c '
    VARIANT_ID=$(basename "{}")
    bash "'"$SCRIPTS_DIR"'/20_test_variant.sh" "$VARIANT_ID"
'

echo "=== Done ==="
