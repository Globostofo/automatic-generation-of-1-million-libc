#!/bin/bash
# =============================================================================
# Script   : 20_build_campaign_tigress_relink.sh
# Purpose  : Generate variants across several Tigress transform combos, each
#            relinked several times with random layout (step 2's proven
#            mechanism) for volume. Mirrors 14_build_campaign_random.sh's
#            "K combos x seeds_per_combo, one job per combo" structure,
#            swapping alignment flags for Tigress transform combos.
#            Fixed to 3 known-safe combos validated this session/project
#            (Flatten alone: palier 3; Split alone: tested locally 2026-08-14;
#            Flatten+Split: palier 4) -- each is a genuinely different
#            Tigress transformation, so Tigress actually contributes real
#            code-level diversity between combos, not just a single fixed
#            pass; the seed-driven volume within a combo comes from layout
#            randomization (Tigress's own --Seed= confirmed not to produce
#            different .text bytes for these transforms, see 18_'s header).
# Usage    : ./scripts/20_build_campaign_tigress_relink.sh [seeds_per_combo] [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

COMBOS=(
    "flatten|Flatten"
    "split|Split"
    "flatten_split|Flatten,Split"
)
K=${#COMBOS[@]}

if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Invalid number of seeds per combo : $1"
    exit 1
fi
SEEDS_PER_COMBO="${1:-7}"

if [ -z "$2" ]; then
    PARALLEL_JOBS="$K"
elif [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]; then
    PARALLEL_JOBS="$2"
else
    echo "Invalid number of parallel jobs : $2"
    exit 1
fi

N=$((K * SEEDS_PER_COMBO))
echo "Generating $N variants ($K transform combos x $SEEDS_PER_COMBO layout seeds) on $PARALLEL_JOBS parallel jobs"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"

mkdir -p "$RESULTS_DIR"
COMBOS_MANIFEST="$RESULTS_DIR/tigress_combos_manifest.txt"
MANIFEST="$RESULTS_DIR/tigress_relink_manifest.txt"
echo "combo_id transform" > "$COMBOS_MANIFEST"
echo "variant_id combo_id seed" > "$MANIFEST"

COMBO_JOBS=()
I=0
for combo in "${COMBOS[@]}"; do
    IFS='|' read -r COMBO_ID TRANSFORM <<< "$combo"
    echo "$COMBO_ID $TRANSFORM" >> "$COMBOS_MANIFEST"

    SEED_LIST=""
    for (( S = 1; S <= SEEDS_PER_COMBO; S++ )); do
        I=$((I + 1))
        VARIANT_ID=$(printf "%04d" "$I")
        SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
        echo "$VARIANT_ID $COMBO_ID $SEED" >> "$MANIFEST"
        SEED_LIST="$SEED_LIST${SEED_LIST:+,}$VARIANT_ID:$SEED"
    done
    COMBO_JOBS+=("$SCRIPTS_DIR|$COMBO_ID|$TRANSFORM|$SEED_LIST")
done

echo "=== Building $K obfuscated bases and relinking $N variants (one job per combo) ==="
printf "%s\n" "${COMBO_JOBS[@]}" | TIGRESS_EXTRA_ARGS="$TIGRESS_EXTRA_ARGS" TIGRESS_EXCLUDES="$TIGRESS_EXCLUDES" \
    xargs -P"$PARALLEL_JOBS" -I{} bash -c '
        IFS="|" read -r SCRIPTS_DIR COMBO_ID TRANSFORM SEED_LIST <<< "{}"
        bash "$SCRIPTS_DIR/18_build_base_tigress_obfuscated.sh" "$COMBO_ID" "$TRANSFORM"
        IFS="," read -ra PAIRS <<< "$SEED_LIST"
        for pair in "${PAIRS[@]}"; do
            IFS=":" read -r VARIANT_ID SEED <<< "$pair"
            bash "$SCRIPTS_DIR/19_build_variant_tigress_relink.sh" "$VARIANT_ID" "$COMBO_ID" "$SEED"
        done
    '

echo "=== Done : $N variants generated across $K combos ==="
echo "    Combos manifest   : $COMBOS_MANIFEST"
echo "    Variants manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv"
