#!/bin/bash
# =============================================================================
# Script   : 07_run_campaign.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by combining compilation flags
# Usage    : ./scripts/07_run_campaign.sh
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

I=1

for o in "${O_LEVELS[@]}"
do
    for f in "${F_FLAGS[@]}"
    do
        if [ -n "$f" ]
        then
            CFLAGS="$o $f"
        else
            CFLAGS="$o"
        fi
        VARIANT_ID=$(printf "%04d" $I)
        bash "$SCRIPTS_DIR/05_build_variant.sh" "$VARIANT_ID" "$CFLAGS"
#        bash "$SCRIPTS_DIR/06_test_variant.sh" "$VARIANT_ID"
        I=$((I+1))
    done
done

echo "=== Done : $((I-1)) variants generated ==="
