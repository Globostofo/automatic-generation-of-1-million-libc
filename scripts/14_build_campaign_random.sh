#!/bin/bash
# =============================================================================
# Script   : 14_build_campaign_random.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Generate musl libc variants by sampling the layout randomization
#            axis: draw K distinct alignment combinations, build each base
#            once (12_build_base_random.sh), then draw `seeds_per_combo`
#            random seeds per combo and relink each variant
#            (13_build_variant_random.sh) without recompiling.
# Usage    : ./scripts/14_build_campaign_random.sh [K] [seeds_per_combo] [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

ALIGN_VALUES=(1 2 4 8 16 32 64)

if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]
then
    echo "Invalid number of combos : $1"
    exit 1
fi
K="${1:-50}"

if [[ -n "$2" && ! "$2" =~ ^[0-9]+$ ]]
then
    echo "Invalid number of seeds per combo : $2"
    exit 1
fi
SEEDS_PER_COMBO="${2:-10}"

if [ -z "$3" ]
then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$3" =~ ^[0-9]+$ && "$3" -gt 0 ]]
then
    PARALLEL_JOBS="$3"
else
    echo "Invalid number of parallel jobs : $3"
    exit 1
fi

N=$((K * SEEDS_PER_COMBO))
echo "Generating $N variants ($K alignment combos x $SEEDS_PER_COMBO seeds) on $PARALLEL_JOBS parallel jobs"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

mkdir -p "$RESULTS_DIR"
COMBOS_MANIFEST="$RESULTS_DIR/random_combos_manifest.txt"
MANIFEST="$RESULTS_DIR/random_manifest.txt"
echo "combo_id align_functions align_loops align_jumps align_labels" > "$COMBOS_MANIFEST"
echo "variant_id combo_id seed" > "$MANIFEST"

declare -A SEEN_COMBOS
COMBO_JOBS=()
VARIANT_JOBS=()

C=0
while [ "$C" -lt "$K" ]
do
    AF="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    AL="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    AJ="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    ALB="${ALIGN_VALUES[$((RANDOM % ${#ALIGN_VALUES[@]}))]}"
    KEY="$AF-$AL-$AJ-$ALB"

    if [ -n "${SEEN_COMBOS[$KEY]}" ]
    then
        continue
    fi
    SEEN_COMBOS[$KEY]=1
    C=$((C+1))

    COMBO_ID=$(printf "%03d" $C)
    echo "$COMBO_ID $AF $AL $AJ $ALB" >> "$COMBOS_MANIFEST"
    COMBO_JOBS+=("$SCRIPTS_DIR|$COMBO_ID|$AF|$AL|$AJ|$ALB")
    echo "combo $COMBO_ID align=$AF/$AL/$AJ/$ALB"

    for (( S=1; S<=SEEDS_PER_COMBO; S++ ))
    do
        VARIANT_ID=$(printf "%04d" $(( (C-1) * SEEDS_PER_COMBO + S )))
        SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
        echo "$VARIANT_ID $COMBO_ID $SEED" >> "$MANIFEST"
        VARIANT_JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$COMBO_ID|$SEED")
    done
done

echo "=== Building $K bases ==="
printf "%s\n" "${COMBO_JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR COMBO_ID AF AL AJ ALB <<< "{}"
    bash "$SCRIPTS_DIR/12_build_base_random.sh" "$COMBO_ID" "$AF" "$AL" "$AJ" "$ALB"
'

echo "=== Building $N variants ==="
printf "%s\n" "${VARIANT_JOBS[@]}" | xargs -P$PARALLEL_JOBS -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID COMBO_ID SEED <<< "{}"
    bash "$SCRIPTS_DIR/13_build_variant_random.sh" "$VARIANT_ID" "$COMBO_ID" "$SEED"
'

echo "=== Done : $N variants generated across $K bases ==="
echo "    Combos manifest   : $COMBOS_MANIFEST"
echo "    Variants manifest : $MANIFEST"
echo ""
echo "Note: base builds are kept under tmp/base_* (not needed once variants are"
echo "built). 99_clean_variants.sh now removes them along with variants/results."
