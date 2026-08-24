#!/bin/bash
# =============================================================================
# Script   : 19_build_campaign_step4.sh
# Purpose  : Step 4 (axis combination). Generate variants combining all three
#            generation axes: obfuscation (step 3, per-file mixed Tigress
#            assignment), compiler flags (step 1's DEDUPLICATED flags list,
#            see below), and layout randomization (step 2's function-order +
#            padding relink).
#
#            Three-tier pipeline, cheapest tier last, so the one genuinely
#            expensive axis (Tigress) is repeated the fewest times:
#              tier 1 (expensive) : 17_build_source_tigress.sh, once per
#                                    Tigress assignment seed -> an obfuscated
#                                    SOURCE tree, not yet compiled with any
#                                    particular flags.
#              tier 2 (cheap)     : 18_build_base_step4.sh, once per
#                                    (assignment seed x flags combo) pair ->
#                                    a compiled base, as fast as step 1's own
#                                    builds since no Tigress runs here.
#              tier 3 (near-free) : 13_build_variant_random.sh (REUSED,
#                                    unchanged), several relink seeds per
#                                    base -> the bulk of the variant volume.
#
#            Flags source: step 1's own report found 720 flag combos collapse
#            to only 248 distinct `.text` hashes on plain musl (~65%
#            duplication, driven almost entirely by the optimization level --
#            see docs/step1_report.md). Crossing the full 720 against Tigress
#            would spend most of tier 2's compute re-deriving combos already
#            known to produce identical code. Instead this script reads the
#            already-deduplicated flags list from
#            "$RESULTS_DIR/step1_distinct_flags.txt" (one CFLAGS string per
#            line) -- regenerate it once via:
#              ./scripts/11_build_campaign_grid.sh
#              ./scripts/30_deduplicate_variants.sh
#              grep '^KEEP' results/deduplication.txt \
#                  | sed -E 's/^KEEP +[0-9]+ +\[(.*)\]$/\1/' \
#                  > results/step1_distinct_flags.txt
#            (this itself is a real, full-scale 720-variant compile -- same
#            cost class as step 1's own original campaign, not something to
#            run casually; 99_clean_variants.sh preserves this file across
#            campaign cleanups, like it already does for toolchain.test.txt).
#            Known, accepted approximation: this dedup was measured on plain
#            (non-obfuscated) musl. Whether the same flag combos collapse to
#            identical output on Tigress-transformed source is not verified
#            (re-verifying would require running Tigress on all 720 combos
#            first -- the exact cost this shortcut exists to avoid) -- worth
#            a documented limitation in the eventual report, not silently
#            assumed permanent.
#
#            Total variants = seeds x len(step1_distinct_flags.txt) x
#            relink_seeds_per_base.
# Usage    : ./scripts/19_build_campaign_step4.sh [tigress_seeds] [relink_seeds_per_base] [parallel_jobs]
#            Env vars (forwarded to 17_build_source_tigress.sh):
#              TIGRESS_EXTRA_ARGS   required, e.g. --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_EXCLUDES     e.g. src/malloc/mallocng/malloc.c
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [[ -n "$1" && ! "$1" =~ ^[0-9]+$ ]]; then
    echo "Invalid number of tigress seeds : $1"
    exit 1
fi
N_SEEDS="${1:-3}"

if [[ -n "$2" && ! "$2" =~ ^[0-9]+$ ]]; then
    echo "Invalid number of relink seeds per base : $2"
    exit 1
fi
RELINK_SEEDS_PER_BASE="${2:-5}"

if [ -z "$3" ]; then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$3" =~ ^[0-9]+$ && "$3" -gt 0 ]]; then
    PARALLEL_JOBS="$3"
else
    echo "Invalid number of parallel jobs : $3"
    exit 1
fi
[ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1

: "${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXTRA_ARGS
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"

# Flags list: step 1's deduplicated survivors (248 of 720 on plain musl),
# NOT the full grid -- see the header comment for why and how to regenerate.
FLAGS_MANIFEST="$RESULTS_DIR/step1_distinct_flags.txt"
if [ ! -s "$FLAGS_MANIFEST" ]; then
    echo "[ERROR] $FLAGS_MANIFEST not found or empty."
    echo "        Regenerate it once (see this script's header comment):"
    echo "          ./scripts/11_build_campaign_grid.sh"
    echo "          ./scripts/30_deduplicate_variants.sh"
    echo "          grep '^KEEP' results/deduplication.txt | sed -E 's/^KEEP +[0-9]+ +\[(.*)\]\$/\1/' > $FLAGS_MANIFEST"
    exit 1
fi
mapfile -t FLAGS_LIST < "$FLAGS_MANIFEST"
N_FLAGS_COMBOS=${#FLAGS_LIST[@]}

N_TOTAL=$((N_SEEDS * N_FLAGS_COMBOS * RELINK_SEEDS_PER_BASE))
echo "Step 4 campaign: $N_SEEDS tigress seeds x $N_FLAGS_COMBOS flags combos x $RELINK_SEEDS_PER_BASE relink seeds = $N_TOTAL variants"
echo "Parallel jobs: $PARALLEL_JOBS"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

mkdir -p "$RESULTS_DIR"
SEEDS_MANIFEST="$RESULTS_DIR/step4_seeds_manifest.txt"
COMBOS_MANIFEST="$RESULTS_DIR/step4_combos_manifest.txt"
MANIFEST="$RESULTS_DIR/step4_manifest.txt"
echo "seed_index assignment_seed" > "$SEEDS_MANIFEST"
echo "combo_id seed_index assignment_seed cflags" > "$COMBOS_MANIFEST"
echo "variant_id combo_id relink_seed" > "$MANIFEST"

# --- Tier 1: obfuscate once per assignment seed. Each 15_ run already uses
#     intra-build parallelism (MAKE_JOBS) internally, so only a small number
#     of seeds run concurrently to avoid oversubscribing the machine. ---
SEEDS=()
for (( S = 1; S <= N_SEEDS; S++ )); do
    ASSIGNMENT_SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
    SEEDS+=("$ASSIGNMENT_SEED")
    echo "$S $ASSIGNMENT_SEED" >> "$SEEDS_MANIFEST"
done

SOURCE_PARALLEL_JOBS=$N_SEEDS
[ "$SOURCE_PARALLEL_JOBS" -gt "$PARALLEL_JOBS" ] && SOURCE_PARALLEL_JOBS=$PARALLEL_JOBS
[ "$SOURCE_PARALLEL_JOBS" -lt 1 ] && SOURCE_PARALLEL_JOBS=1
MAKE_JOBS_PER_SEED=$(( $(nproc) / SOURCE_PARALLEL_JOBS ))
[ "$MAKE_JOBS_PER_SEED" -lt 1 ] && MAKE_JOBS_PER_SEED=1

echo "=== Tier 1: obfuscating $N_SEEDS source corpora ($SOURCE_PARALLEL_JOBS parallel, $MAKE_JOBS_PER_SEED make jobs each) ==="
printf "%s\n" "${SEEDS[@]}" | MAKE_JOBS="$MAKE_JOBS_PER_SEED" \
    xargs -P"$SOURCE_PARALLEL_JOBS" -I{} bash -c '
        bash "'"$SCRIPTS_DIR"'/17_build_source_tigress.sh" "{}"
    '

# --- Tiers 2+3: one job per (seed, flags combo) pair -- builds the base
#     then relinks all its variants, mirroring 14_build_campaign_random.sh's
#     "one job per combo" pattern so a combo that finishes compiling early
#     starts relinking immediately instead of waiting on the others. ---
COMBO_JOBS=()
VARIANT_COUNTER=0
for (( S = 1; S <= N_SEEDS; S++ )); do
    ASSIGNMENT_SEED="${SEEDS[$((S - 1))]}"
    for (( F = 1; F <= N_FLAGS_COMBOS; F++ )); do
        FLAGS_ID=$(printf "%04d" "$F")
        CFLAGS="${FLAGS_LIST[$((F - 1))]}"
        COMBO_ID="${S}_${FLAGS_ID}"
        echo "$COMBO_ID $S $ASSIGNMENT_SEED $CFLAGS" >> "$COMBOS_MANIFEST"

        SEED_LIST=""
        for (( R = 1; R <= RELINK_SEEDS_PER_BASE; R++ )); do
            VARIANT_COUNTER=$((VARIANT_COUNTER + 1))
            VARIANT_ID=$(printf "%05d" "$VARIANT_COUNTER")
            RELINK_SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
            echo "$VARIANT_ID $COMBO_ID $RELINK_SEED" >> "$MANIFEST"
            SEED_LIST="$SEED_LIST${SEED_LIST:+,}$VARIANT_ID:$RELINK_SEED"
        done
        COMBO_JOBS+=("$SCRIPTS_DIR|$COMBO_ID|$ASSIGNMENT_SEED|$CFLAGS|$SEED_LIST")
    done
done

echo "=== Tiers 2+3: building $((N_SEEDS * N_FLAGS_COMBOS)) bases and relinking $N_TOTAL variants ==="
printf "%s\n" "${COMBO_JOBS[@]}" | xargs -P"$PARALLEL_JOBS" -I{} bash -c '
    IFS="|" read -r SCRIPTS_DIR COMBO_ID ASSIGNMENT_SEED CFLAGS SEED_LIST <<< "{}"
    bash "$SCRIPTS_DIR/18_build_base_step4.sh" "$COMBO_ID" "$ASSIGNMENT_SEED" "$CFLAGS"
    IFS="," read -ra PAIRS <<< "$SEED_LIST"
    for pair in "${PAIRS[@]}"; do
        IFS=":" read -r VARIANT_ID RELINK_SEED <<< "$pair"
        bash "$SCRIPTS_DIR/13_build_variant_random.sh" "$VARIANT_ID" "$COMBO_ID" "$RELINK_SEED"
    done
'

echo "=== Done : $N_TOTAL variants generated across $((N_SEEDS * N_FLAGS_COMBOS)) bases ==="
echo "    Seeds manifest    : $SEEDS_MANIFEST"
echo "    Combos manifest   : $COMBOS_MANIFEST"
echo "    Variants manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv <n_clusters>"
