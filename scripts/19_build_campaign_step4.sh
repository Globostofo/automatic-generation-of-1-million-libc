#!/bin/bash
# =============================================================================
# Script   : 19_build_campaign_step4.sh
# Purpose  : Step 4 (axis combination). Generate variants combining all three
#            generation axes: obfuscation (step 3, per-file mixed Tigress
#            assignment), compiler flags (step 1's flag axes, RANDOMLY
#            SAMPLED -- see below), and layout randomization (step 2's
#            function-order + padding relink).
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
#            Flags source: a fixed number (flags_combos) of DISTINCT flag
#            tuples drawn at random from the same 5 axes as step 1's grid
#            (optimization level x inlining x unrolling x frame pointer x
#            march/mtune), mirroring how steps 2 and 3 already draw a fixed
#            N rather than enumerating exhaustively -- step 1 itself is not
#            touched or depended on here (no prerequisite campaign, no
#            manifest file to regenerate). Two deliberate consequences of
#            this choice, both accepted:
#              - unlike a full-grid crossing, this can't guarantee hitting
#                every distinct "shape" step 1 found (optimization level
#                dominates step 1's own clustering -- see
#                docs/step1_report.md -- so a modest flags_combos should
#                still cover most of the real diversity in practice, but
#                this isn't exhaustive by construction);
#              - some drawn combos may still turn out to produce identical
#                `.text` once compiled -- this is NOT pre-filtered using step
#                1's plain-musl duplication numbers (which don't necessarily
#                transfer to Tigress-obfuscated source, an open question this
#                design sidesteps rather than assumes); instead
#                30_deduplicate_variants.sh measures the real duplication
#                rate on the actual obfuscated+flags output, same as every
#                other step already does.
#
#            Total variants = seeds x flags_combos x relink_seeds_per_base.
# Usage    : ./scripts/19_build_campaign_step4.sh [tigress_seeds] [flags_combos] [relink_seeds_per_base] [parallel_jobs]
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
    echo "Invalid number of flags combos : $2"
    exit 1
fi
N_FLAGS_COMBOS="${2:-250}"

if [[ -n "$3" && ! "$3" =~ ^[0-9]+$ ]]; then
    echo "Invalid number of relink seeds per base : $3"
    exit 1
fi
RELINK_SEEDS_PER_BASE="${3:-5}"

if [ -z "$4" ]; then
    PARALLEL_JOBS=$(( $(nproc) / 2 ))
elif [[ "$4" =~ ^[0-9]+$ && "$4" -gt 0 ]]; then
    PARALLEL_JOBS="$4"
else
    echo "Invalid number of parallel jobs : $4"
    exit 1
fi
[ "$PARALLEL_JOBS" -lt 1 ] && PARALLEL_JOBS=1

: "${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXTRA_ARGS
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"

# Flags list: N_FLAGS_COMBOS DISTINCT tuples drawn at random from step 1's
# own axes -- not the full 720-combo grid, not a dependency on step 1's own
# scripts/results. Same distinct-draw pattern as 14_build_campaign_random.sh
# uses for alignment combos.
O_LEVELS=("-O0" "-O1" "-O2" "-O3" "-Os" "-Og")
INLINE_FLAGS=("" "-fno-inline" "-fno-inline-functions" "-finline-functions")
UNROLL_FLAGS=("" "-fno-unroll-loops" "-funroll-loops")
FRAME_FLAGS=("" "-fno-omit-frame-pointer")
MARCH_FLAGS=("" "-march=x86-64" "-march=x86-64-v2" "-march=x86-64-v3" "-mtune=native")
MAX_FLAGS_COMBOS=$(( ${#O_LEVELS[@]} * ${#INLINE_FLAGS[@]} * ${#UNROLL_FLAGS[@]} * ${#FRAME_FLAGS[@]} * ${#MARCH_FLAGS[@]} ))
if [ "$N_FLAGS_COMBOS" -gt "$MAX_FLAGS_COMBOS" ]; then
    echo "[ERROR] flags_combos ($N_FLAGS_COMBOS) exceeds the full grid size ($MAX_FLAGS_COMBOS) -- can't draw that many distinct tuples."
    exit 1
fi

declare -A SEEN_FLAGS
FLAGS_LIST=()
F=0
while [ "$F" -lt "$N_FLAGS_COMBOS" ]; do
    o="${O_LEVELS[$((RANDOM % ${#O_LEVELS[@]}))]}"
    inline="${INLINE_FLAGS[$((RANDOM % ${#INLINE_FLAGS[@]}))]}"
    unroll="${UNROLL_FLAGS[$((RANDOM % ${#UNROLL_FLAGS[@]}))]}"
    frame="${FRAME_FLAGS[$((RANDOM % ${#FRAME_FLAGS[@]}))]}"
    march="${MARCH_FLAGS[$((RANDOM % ${#MARCH_FLAGS[@]}))]}"
    KEY="$o|$inline|$unroll|$frame|$march"
    if [ -n "${SEEN_FLAGS[$KEY]}" ]; then
        continue
    fi
    SEEN_FLAGS[$KEY]=1
    F=$((F + 1))
    CFLAGS=$(echo "$o $inline $unroll $frame $march" | tr -s ' ' | sed 's/^ //;s/ $//')
    FLAGS_LIST+=("$CFLAGS")
done

N_TOTAL=$((N_SEEDS * N_FLAGS_COMBOS * RELINK_SEEDS_PER_BASE))
echo "Step 4 campaign: $N_SEEDS tigress seeds x $N_FLAGS_COMBOS flags combos x $RELINK_SEEDS_PER_BASE relink seeds = $N_TOTAL variants"
echo "Parallel jobs: $PARALLEL_JOBS"

echo "=== Syncing musl sources ==="
bash "$SCRIPTS_DIR/01_sync_dependencies.sh" musl

mkdir -p "$RESULTS_DIR"
SEEDS_MANIFEST="$RESULTS_DIR/step4_seeds_manifest.txt"
FLAGS_MANIFEST="$RESULTS_DIR/step4_flags_manifest.txt"
COMBOS_MANIFEST="$RESULTS_DIR/step4_combos_manifest.txt"
MANIFEST="$RESULTS_DIR/step4_manifest.txt"
echo "seed_index assignment_seed" > "$SEEDS_MANIFEST"
echo "flags_id cflags" > "$FLAGS_MANIFEST"
for (( F = 1; F <= N_FLAGS_COMBOS; F++ )); do
    echo "$(printf "%04d" "$F") ${FLAGS_LIST[$((F - 1))]}" >> "$FLAGS_MANIFEST"
done
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
echo "    Flags manifest    : $FLAGS_MANIFEST"
echo "    Combos manifest   : $COMBOS_MANIFEST"
echo "    Variants manifest : $MANIFEST"
echo ""
echo "Next: gate + measure diversity with the existing scripts, unchanged:"
echo "    $SCRIPTS_DIR/22_test_campaign_parallel.sh"
echo "    $SCRIPTS_DIR/30_deduplicate_variants.sh"
echo "    $SCRIPTS_DIR/32_jaccard_distances.py 3"
echo "    $SCRIPTS_DIR/34_clustering.py results/jaccard_n3_matrix.csv <n_clusters>"
