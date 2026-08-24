#!/bin/bash
# =============================================================================
# Script   : 20_build_campaign_tigress_relink.sh
# Purpose  : Generate N variants from ONE obfuscated Tigress base, relinked
#            with random function order + padding per variant (step 3's
#            urgent fallback diversity mechanism, see 18_'s header). Builds
#            the base once, then relinks all N variants in parallel.
# Usage    : ./scripts/20_build_campaign_tigress_relink.sh [N] [parallel_jobs]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Invalid number of variants : $1"
    exit 1
fi
N="${1:-20}"

if [ -z "$2" ]; then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]; then
    PARALLEL_JOBS="$2"
else
    echo "Invalid number of parallel jobs : $2"
    exit 1
fi

echo "Generating $N variants from one obfuscated base, relinked on $PARALLEL_JOBS parallel jobs"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

echo "=== Building the one obfuscated base ==="
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
bash "$SCRIPTS_DIR/18_build_base_tigress_obfuscated.sh"

mkdir -p "$RESULTS_DIR"
MANIFEST="$RESULTS_DIR/tigress_relink_manifest.txt"
echo "variant_id seed" > "$MANIFEST"

VARIANT_JOBS=()
for (( I = 1; I <= N; I++ )); do
    VARIANT_ID=$(printf "%04d" "$I")
    SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
    echo "$VARIANT_ID $SEED" >> "$MANIFEST"
    VARIANT_JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$SEED")
done

echo "=== Relinking $N variants ==="
printf "%s\n" "${VARIANT_JOBS[@]}" | xargs -P"$PARALLEL_JOBS" -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR VARIANT_ID SEED <<< "{}"
    bash "$SCRIPTS_DIR/19_build_variant_tigress_relink.sh" "$VARIANT_ID" "$SEED"
'

echo "=== Done : $N variants generated ==="
echo "    Manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv"
