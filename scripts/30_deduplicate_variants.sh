#!/bin/bash
# =============================================================================
# Script   : 30_deduplicate_variants.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Remove duplicate variants based on .text section SHA256 hash
# Usage    : ./scripts/30_deduplicate_variants.sh
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

DEDUP_REPORT="$RESULTS_DIR/deduplication.txt"
> "$DEDUP_REPORT"

declare -A SEEN_HASHES
KEPT=0
REMOVED=0

for meta in $(ls "$RESULTS_DIR"/[0-9]*.meta.txt | sort)
do
    VARIANT_ID=$(grep "variant_id" "$meta" | awk '{print $3}')
    HASH=$(grep "sha256_text" "$meta" | awk '{print $3}')
    CFLAGS=$(grep "cflags" "$meta" | awk -F': ' '{print $2}')

    if [ -z "${SEEN_HASHES[$HASH]}" ]
    then
        SEEN_HASHES[$HASH]="$VARIANT_ID"
        echo "KEEP    $VARIANT_ID [$CFLAGS]" | tee -a "$DEDUP_REPORT"
        KEPT=$((KEPT+1))
    else
        echo "REMOVE  $VARIANT_ID [$CFLAGS] (duplicate of ${SEEN_HASHES[$HASH]})" | tee -a "$DEDUP_REPORT"
        rm -rf "$VARIANTS_DIR/$VARIANT_ID"
        rm -f "$RESULTS_DIR/$VARIANT_ID".*
        REMOVED=$((REMOVED+1))
    fi
done

echo "=== Deduplication done ==="
echo "    Kept    : $KEPT"
echo "    Removed : $REMOVED"
echo "    Report  : $DEDUP_REPORT"
