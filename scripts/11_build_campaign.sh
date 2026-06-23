#!/bin/bash
# =============================================================================
# Script   : 11_build_campaign.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by combining compilation flags
# Usage    : ./scripts/11_build_campaign.sh [parallel_jobs]
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

printf "%s\n" "${JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID CFLAGS <<< "{}"
    bash "$SCRIPTS_DIR/05_build_variant.sh" "$VARIANT_ID" "$CFLAGS"
'

echo "=== Done : $((I-1)) variants generated ==="
