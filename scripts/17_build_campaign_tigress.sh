#!/bin/bash
# =============================================================================
# Script   : 17_build_campaign_tigress.sh
# Purpose  : Generate N Tigress-obfuscated musl variants, one per random seed,
#            sharing a single prep cache (15_build_base_tigress.sh, run once
#            up front) across all of them. Unlike step 2's campaign, each
#            variant here still needs a full recompile (the Tigress transform
#            changes actual object code, not just link order) -- so
#            parallelism is split two ways: PARALLEL_JOBS variants in flight
#            at once, each internally using MAKE_JOBS make jobs, sized so
#            PARALLEL_JOBS * MAKE_JOBS stays close to nproc instead of
#            oversubscribing.
# Usage    : ./scripts/17_build_campaign_tigress.sh [N] [parallel_jobs]
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
    PARALLEL_JOBS=4
elif [[ "$2" =~ ^[0-9]+$ && "$2" -gt 0 ]]; then
    PARALLEL_JOBS="$2"
else
    echo "Invalid number of parallel jobs : $2"
    exit 1
fi

MAKE_JOBS_PER_VARIANT=$(( $(nproc) / PARALLEL_JOBS ))
[ "$MAKE_JOBS_PER_VARIANT" -lt 1 ] && MAKE_JOBS_PER_VARIANT=1

echo "Generating $N Tigress variants on $PARALLEL_JOBS parallel jobs ($MAKE_JOBS_PER_VARIANT make jobs each)"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

echo "=== Warming prep cache (once, shared by every variant) ==="
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
bash "$SCRIPTS_DIR/15_build_base_tigress.sh"

mkdir -p "$RESULTS_DIR"
MANIFEST="$RESULTS_DIR/tigress_manifest.txt"
echo "variant_id seed" > "$MANIFEST"

VARIANT_JOBS=()
for (( I = 1; I <= N; I++ )); do
    # Plain zero-padded number, same as steps 1-2 -- 22_test_campaign_parallel.sh,
    # 30_deduplicate_variants.sh and tools.py all only pick up variant
    # directories whose name is purely numeric (`v.isdigit()`).
    VARIANT_ID=$(printf "%04d" "$I")
    SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
    echo "$VARIANT_ID $SEED" >> "$MANIFEST"
    VARIANT_JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$SEED")
done

echo "=== Building $N variants ==="
printf "%s\n" "${VARIANT_JOBS[@]}" | MAKE_JOBS="$MAKE_JOBS_PER_VARIANT" TIGRESS_EXTRA_ARGS="$TIGRESS_EXTRA_ARGS" TIGRESS_EXCLUDES="$TIGRESS_EXCLUDES" \
    xargs -P"$PARALLEL_JOBS" -I{} bash -c '
        IFS="|" read -r SCRIPTS_DIR VARIANT_ID SEED <<< "{}"
        bash "$SCRIPTS_DIR/16_build_variant_tigress.sh" "$VARIANT_ID" "$SEED"
    '

echo "=== Done : $N variants generated ==="
echo "    Manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv"
