#!/bin/bash
# =============================================================================
# Script   : 16_build_campaign_tigress_mixed.sh
# Purpose  : Generate N musl variants, each with its own independent
#            per-file random Tigress transform assignment (see
#            15_build_variant_tigress_mixed.sh and
#            tigress_cc_wrapper.sh's TIGRESS_ASSIGNMENT_SEED). No relink
#            step -- deliberately, to measure obfuscation's own diversity
#            contribution in isolation from step 2's layout-randomization
#            mechanism (see docs/step3_design.md). Every variant is
#            therefore a full, independent corpus compile: substantially
#            more expensive per variant than the previous K-combo+relink
#            campaign, so N here should stay an order of magnitude smaller
#            (tens, not hundreds) unless there is a specific reason to
#            afford more.
# Usage    : ./scripts/16_build_campaign_tigress_mixed.sh [N] [parallel_jobs]
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

echo "Generating $N mixed-assignment variants on $PARALLEL_JOBS parallel jobs ($MAKE_JOBS_PER_VARIANT make jobs each)"
echo "No relink -- every variant is an independent full corpus compile."

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
export TIGRESS_BASE_CACHE="${TIGRESS_BASE_CACHE:-$BASE_DIR/tmp/tigress_mixed_cache}"
# Shared across every variant in this campaign, deliberately: with only 5
# possible transforms per file and TIGRESS_SEED fixed, independent variants
# frequently re-request the same (file, transform) pair by chance -- caching
# it means the total unique Tigress work across the WHOLE campaign converges
# to roughly 5 full-corpus passes (at most, one per transform per file),
# regardless of N, instead of N full passes. Validated locally: two variants
# sharing a cold-then-warm cache went from 6m06s to 3m04s. Set
# TIGRESS_OUTPUT_CACHE="" before calling this script to disable if ever
# needed (e.g. to force independent timing measurements per variant).
export TIGRESS_OUTPUT_CACHE="${TIGRESS_OUTPUT_CACHE-$BASE_DIR/tmp/tigress_mixed_output_cache}"
rm -rf "$TIGRESS_BASE_CACHE" "$TIGRESS_OUTPUT_CACHE"
mkdir -p "$TIGRESS_BASE_CACHE" "$RESULTS_DIR"
[ -n "$TIGRESS_OUTPUT_CACHE" ] && mkdir -p "$TIGRESS_OUTPUT_CACHE"

MANIFEST="$RESULTS_DIR/tigress_mixed_manifest.txt"
echo "variant_id assignment_seed" > "$MANIFEST"

VARIANT_JOBS=()
for (( I = 1; I <= N; I++ )); do
    VARIANT_ID=$(printf "%04d" "$I")
    SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
    echo "$VARIANT_ID $SEED" >> "$MANIFEST"
    VARIANT_JOBS+=("$SCRIPTS_DIR|$VARIANT_ID|$SEED")
done

echo "=== Building $N variants ==="
printf "%s\n" "${VARIANT_JOBS[@]}" | MAKE_JOBS="$MAKE_JOBS_PER_VARIANT" TIGRESS_EXTRA_ARGS="$TIGRESS_EXTRA_ARGS" TIGRESS_EXCLUDES="$TIGRESS_EXCLUDES" TIGRESS_BASE_CACHE="$TIGRESS_BASE_CACHE" TIGRESS_OUTPUT_CACHE="$TIGRESS_OUTPUT_CACHE" \
    xargs -P"$PARALLEL_JOBS" -I{} bash -c '
        IFS="|" read -r SCRIPTS_DIR VARIANT_ID SEED <<< "{}"
        bash "$SCRIPTS_DIR/15_build_variant_tigress_mixed.sh" "$VARIANT_ID" "$SEED"
    '

echo "=== Done : $N variants generated ==="
echo "    Manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv <n_clusters>"
