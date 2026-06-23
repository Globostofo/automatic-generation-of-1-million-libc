#!/bin/bash
# =============================================================================
# Script   : 06_run_campaign.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by combining compilation flags
# Usage    : ./scripts/06_run_campaign.sh
# =============================================================================

set -e

SCRIPTS_DIR=$(dirname "$0")
source "$SCRIPTS_DIR/config.sh"

O_LEVELS=("-O0" "-O1" "-O2" "-O3" "-Os" "-Og")

F_FLAGS=(
    ""
    "-fno-inline"
    "-fno-unroll-loops"
    "-fomit-frame-pointer"
    "-fno-omit-frame-pointer"
    "-fstack-protector"
    "-fstack-protector-strong"
    "-fno-strict-aliasing"
    "-ffunction-sections"
    "-fdata-sections"
    "-fno-inline -fno-unroll-loops"
    "-fstack-protector -fno-omit-frame-pointer"
)

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

I=1
JOBS=()

for o in "${O_LEVELS[@]}"
do
    for f in "${F_FLAGS[@]}"
    do
        [ -n "$f" ] &&  CFLAGS="$o $f" || CFLAGS="$o"
        VARIANT_ID=$(printf "%04d" $I)
        JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$CFLAGS")
        I=$((I+1))
    done
done

PARALLEL_JOBS=$(( $(nproc) / 2 ))
printf "%s\n" "${JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID CFLAGS <<< "{}"
    bash "$SCRIPTS_DIR/05_build_variant.sh" "$VARIANT_ID" "$CFLAGS"
'

echo "=== Done : $((I-1)) variants generated ==="
