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
#            Dispatch: each Tigress assignment seed runs its own full
#            pipeline (tier 1 -> its own tier 2/3) as ONE job, via this same
#            script self-invoked with --seed-pipeline. Tier 2/3 for a given
#            seed starts as soon as THAT seed's tier 1 finishes, without
#            waiting on the other seeds -- mirrors 14_build_campaign_random.sh's
#            own "a combo that finishes compiling early starts relinking
#            without waiting for the others" principle, one level up. The
#            previous design had a hard barrier (ALL seeds' tier 1 had to
#            finish before ANY tier 2 could start), which cost real wall
#            time whenever seeds don't finish tier 1 at the same moment.
#            Accepted tradeoff: core allocation is no longer strictly
#            phase-separated (a seed still in tier 1 and another already in
#            tier 2 can be using cores at the same time), so the two
#            per-phase job counts below are sized as a reasonable split of
#            the total budget, not a hard guarantee against ever
#            oversubscribing -- acceptable since tier 2's individual builds
#            are cheap/short, not a correctness concern either way.
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

# --- Internal seed-pipeline mode ------------------------------------------
# Invoked by this same script's own dispatch loop below (self-invocation),
# one process per Tigress assignment seed, running concurrently with the
# other seeds' pipelines. Runs tier 1 for this seed, then immediately
# dispatches tier 2/3 for exactly this seed's combos (pre-computed by the
# main invocation into a per-seed job file, same job-string format
# 14_build_campaign_random.sh's own combo dispatch already established) --
# removing the barrier a single flat "all tier 1, then all tier 2/3"
# dispatch would impose.
if [ "${1:-}" = "--seed-pipeline" ]; then
    ASSIGNMENT_SEED="$2"
    COMBO_PARALLEL_PER_SEED="$3"
    JOBS_FILE="$4"

    bash "$SCRIPTS_DIR/17_build_source_tigress.sh" "$ASSIGNMENT_SEED"

    xargs -P"$COMBO_PARALLEL_PER_SEED" -I{} bash -c '
        IFS="|" read -r SCRIPTS_DIR COMBO_ID ASSIGNMENT_SEED CFLAGS SEED_LIST <<< "{}"
        bash "$SCRIPTS_DIR/18_build_base_step4.sh" "$COMBO_ID" "$ASSIGNMENT_SEED" "$CFLAGS"
        IFS="," read -ra PAIRS <<< "$SEED_LIST"
        for pair in "${PAIRS[@]}"; do
            IFS=":" read -r VARIANT_ID RELINK_SEED <<< "$pair"
            bash "$SCRIPTS_DIR/13_build_variant_random.sh" "$VARIANT_ID" "$COMBO_ID" "$RELINK_SEED"
        done
        # This combo will never be revisited (each combo is built and
        # relinked exactly once per campaign) -- free its base right away
        # instead of letting it sit in tmp/ until 99_clean_variants.sh runs
        # at the very end. At the default scale (750 bases, each a full
        # musl build dir with .o files + install/) this is the difference
        # between tmp/ staying bounded to whatever is actively in flight
        # vs. accumulating every base the whole campaign ever built.
        rm -rf "'"$BASE_DIR"'/tmp/base_$COMBO_ID"
    ' < "$JOBS_FILE"

    exit 0
fi
# ---------------------------------------------------------------------------

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

# Shared Tigress prep cache (reference-compile + preprocess + stub-main) --
# seed-independent (only the final transform pick varies by seed), so
# sharing it across every seed-pipeline avoids redoing this work once per
# seed. Created fresh per campaign run.
STEP4_PREP_CACHE="$BASE_DIR/tmp/source_tigress_prep_cache"
rm -rf "$STEP4_PREP_CACHE"
mkdir -p "$STEP4_PREP_CACHE"
export TIGRESS_BASE_CACHE="$STEP4_PREP_CACHE"

SEED_JOBS_DIR="$BASE_DIR/tmp/step4_seed_jobs"
rm -rf "$SEED_JOBS_DIR"
mkdir -p "$SEED_JOBS_DIR"

SEEDS=()
SEED_PIPELINE_ARGS=()
VARIANT_COUNTER=0
for (( S = 1; S <= N_SEEDS; S++ )); do
    ASSIGNMENT_SEED=$(( (RANDOM << 16) ^ (RANDOM << 1) ^ RANDOM ))
    SEEDS+=("$ASSIGNMENT_SEED")
    echo "$S $ASSIGNMENT_SEED" >> "$SEEDS_MANIFEST"

    JOBS_FILE="$SEED_JOBS_DIR/$S.txt"
    : > "$JOBS_FILE"
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
        echo "$SCRIPTS_DIR|$COMBO_ID|$ASSIGNMENT_SEED|$CFLAGS|$SEED_LIST" >> "$JOBS_FILE"
    done
    SEED_PIPELINE_ARGS+=("$ASSIGNMENT_SEED|$JOBS_FILE")
done

# Split the total job budget between how many seed-pipelines run at once
# and how much fan-out each pipeline gets for its own tier 2/3 once it gets
# there -- see the header comment for why this is a reasonable split, not
# a hard oversubscription guarantee now that phases can interleave across
# seeds.
SEED_PARALLEL_JOBS=$N_SEEDS
[ "$SEED_PARALLEL_JOBS" -gt "$PARALLEL_JOBS" ] && SEED_PARALLEL_JOBS=$PARALLEL_JOBS
[ "$SEED_PARALLEL_JOBS" -lt 1 ] && SEED_PARALLEL_JOBS=1
MAKE_JOBS_PER_SEED=$(( $(nproc) / SEED_PARALLEL_JOBS ))
[ "$MAKE_JOBS_PER_SEED" -lt 1 ] && MAKE_JOBS_PER_SEED=1
COMBO_PARALLEL_PER_SEED=$(( PARALLEL_JOBS / SEED_PARALLEL_JOBS ))
[ "$COMBO_PARALLEL_PER_SEED" -lt 1 ] && COMBO_PARALLEL_PER_SEED=1

echo "=== Dispatching $N_SEEDS seed pipelines ($SEED_PARALLEL_JOBS parallel, $MAKE_JOBS_PER_SEED make jobs each for tier 1, $COMBO_PARALLEL_PER_SEED parallel tier 2/3 builds per seed) ==="
printf "%s\n" "${SEED_PIPELINE_ARGS[@]}" | MAKE_JOBS="$MAKE_JOBS_PER_SEED" \
    xargs -P"$SEED_PARALLEL_JOBS" -I{} bash -c '
        IFS="|" read -r ASSIGNMENT_SEED JOBS_FILE <<< "{}"
        bash "'"$SCRIPTS_DIR"'/19_build_campaign_step4.sh" --seed-pipeline "$ASSIGNMENT_SEED" "'"$COMBO_PARALLEL_PER_SEED"'" "$JOBS_FILE"
    '

rm -rf "$SEED_JOBS_DIR"

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
