#!/bin/bash
# =============================================================================
# Script   : 12_build_campaign_random.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by randomly sampling the layout
#            randomization axis (alignment jitter + function order/padding
#            seed), with the base optimization level fixed to -O2 in order to
#            isolate this axis from the flags axis explored in step 1
# Usage    : ./scripts/12_build_campaign_random.sh [N] [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

ALIGN_VALUES=(1 2 4 8 16 32 64)

if [ -z "$1" ]
then
    N=500
elif [[ "$1" =~ ^[0-9]+$ && "$1" -gt 0 ]]
then
    N="$1"
else
    echo "Invalid number of variants : $1"
    exit 1
fi

if [ -z "$2" ]
then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]
then
    PARALLEL_JOBS="$2"
else
    echo "Invalid number of parallel jobs : $2"
    exit 1
fi
echo "Generating $N variants on $PARALLEL_JOBS parallel jobs"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

MANIFEST="$RESULTS_DIR/random_manifest.txt"
mkdir -p "$RESULTS_DIR"
echo "variant_id align_functions align_loops align_jumps align_labels seed" > "$MANIFEST"

JOBS=()

for (( I=1; I<=N; I++ ))
do
    VARIANT_ID=$(printf "%04d" $I)
    AF="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    AL="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    AJ="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    ALB="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))

    echo "$VARIANT_ID $AF $AL $AJ $ALB $SEED" >> "$MANIFEST"
    JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$AF|$AL|$AJ|$ALB|$SEED")
    echo "$VARIANT_ID align=$AF/$AL/$AJ/$ALB seed=$SEED"
done

echo "=== Generating $N variants ==="

printf "%s\n" "${JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID AF AL AJ ALB SEED <<< "{}"
    bash "$SCRIPTS_DIR/13_build_variant_random.sh" "$VARIANT_ID" "$AF" "$AL" "$AJ" "$ALB" "$SEED"
'

echo "=== Done : $N variants generated ==="
echo "    Manifest : $MANIFEST"
