#!/bin/bash
# =============================================================================
# Script   : 11_build_campaign_grid.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by combining compilation flags
#            using a grid search strategy
# Usage    : ./scripts/11_build_campaign_grid.sh [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR=$(dirname "$0")
source "$SCRIPTS_DIR/config.sh"

O_LEVELS=("-O0" "-O1" "-O2" "-O3" "-Os" "-Og")

INLINE_FLAGS=(
    ""
    "-fno-inline"
    "-fno-inline-functions"
    "-finline-functions"
)

UNROLL_FLAGS=(
    ""
    "-fno-unroll-loops"
    "-funroll-loops"
)

FRAME_FLAGS=(
    ""
    "-fno-omit-frame-pointer"
)

MARCH_FLAGS=(
    ""
    "-march=x86-64"
    "-march=x86-64-v2"
    "-march=x86-64-v3"
    "-mtune=native"
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
    for inline in "${INLINE_FLAGS[@]}"
    do
        for unroll in "${UNROLL_FLAGS[@]}"
        do
            for frame in "${FRAME_FLAGS[@]}"
            do
                for march in "${MARCH_FLAGS[@]}"
                do
                    VARIANT_ID=$(printf "%04d" $I)
                    CFLAGS=$(echo "$o $inline $unroll $frame $march" | tr -s ' ' | sed 's/^ //;s/ $//')
                    JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$CFLAGS")
                    I=$((I+1))
                    echo $VARIANT_ID $CFLAGS
                done
            done
        done
    done
done

echo "=== Generating $((I-1)) variants ==="

printf "%s\n" "${JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID CFLAGS <<< "{}"
    bash "$SCRIPTS_DIR/10_build_variant.sh" "$VARIANT_ID" "$CFLAGS"
'

echo "=== Done : $((I-1)) variants generated ==="
