#!/bin/bash
# =============================================================================
# Script   : 17_build_source_tigress.sh
# Purpose  : Step 4 (axis combination). Obfuscate the whole musl corpus ONCE
#            for a given Tigress assignment seed (per-file mixed transform
#            assignment, same mechanism as 15_build_variant_tigress_mixed.sh)
#            and persist the result as a SOURCE tree under
#            tmp/obfuscated_<seed>/, mirroring musl's src/ layout, instead of
#            compiling it into a specific libc.so. This is what lets step 4
#            cross Tigress's obfuscation axis against step 1's full 720-combo
#            flag grid without rerunning Tigress per combo: 18_build_base_step4.sh
#            overlays this tree on a fresh musl checkout and compiles it with
#            an arbitrary CFLAGS combo using the plain compiler, no wrapper
#            involved at that stage.
#
#            A real `make lib/libc.so` still has to run here (driven through
#            the wrapper) so every eligible file actually gets compiled once
#            and thus dumped -- the resulting libc.so itself is a throwaway
#            byproduct, not step 4's deliverable.
# Usage    : ./scripts/17_build_source_tigress.sh <assignment_seed>
#            Env vars:
#              TIGRESS_EXTRA_ARGS   required, e.g. --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_SEED         Tigress's own --Seed=, fixed (default: 1)
#              TIGRESS_EXCLUDES     e.g. src/malloc/mallocng/malloc.c, see
#                                   tigress_cc_wrapper.sh header
#              MAKE_JOBS            intra-build parallelism (default: nproc)
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <assignment_seed>"
    exit 1
fi

ASSIGNMENT_SEED="$1"

BUILD_DIR="$BASE_DIR/tmp/build_source_tigress_$ASSIGNMENT_SEED"
SOURCE_DIR="$BASE_DIR/tmp/obfuscated_$ASSIGNMENT_SEED"
LOG="$RESULTS_DIR/source_tigress_$ASSIGNMENT_SEED.build.log"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

export TIGRESS_PHASE=variant
export TIGRESS_ASSIGNMENT_SEED="$ASSIGNMENT_SEED"
export TIGRESS_SEED="${TIGRESS_SEED:-1}"
export REALCC="${REALCC:-gcc}"
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
export TIGRESS_TMP="$BASE_DIR/tmp/source_tigress_${ASSIGNMENT_SEED}_scratch"
export TIGRESS_BASE_CACHE="$BASE_DIR/tmp/source_tigress_${ASSIGNMENT_SEED}_cache"
export TIGRESS_OUTPUT_CACHE=""
export TIGRESS_OUTPUT_SOURCE_DIR="$SOURCE_DIR"
export TIGRESS_REPORT="$RESULTS_DIR/source_tigress_$ASSIGNMENT_SEED.tigress_report.txt"

echo "=== Obfuscating source corpus for assignment seed $ASSIGNMENT_SEED ==="

rm -rf "$SOURCE_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE" "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$SOURCE_DIR" "$RESULTS_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"
: > "$TIGRESS_REPORT"

cp -r "$MUSL_DIR/." "$BUILD_DIR/"

(
    cd "$BUILD_DIR"

    ./configure \
        --prefix="$BUILD_DIR/install" \
        --syslibdir="$BUILD_DIR/install/lib" \
        CC="$SCRIPTS_DIR/tigress_cc_wrapper.sh" \
        >> "$LOG" 2>&1

    echo "Compiling (running $MAKE_JOBS parallel jobs, per-file random transform assignment)..."
    make -j"$MAKE_JOBS" lib/libc.so >> "$LOG" 2>&1
)

rm -rf "$BUILD_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"

OK=$(grep -c '^OK ' "$TIGRESS_REPORT" || true)
FALLBACK=$(grep -c '^FALLBACK ' "$TIGRESS_REPORT" || true)
N_FILES=$(find "$SOURCE_DIR" -name '*.c' | wc -l)

BREAKDOWN=$(awk '$1=="OK"{print $3}' "$TIGRESS_REPORT" | sort | uniq -c | sort -rn | awk '{printf "%s:%s ", $2, $1}')

META="$RESULTS_DIR/source_tigress_$ASSIGNMENT_SEED.meta.txt"
cat > "$META" << EOF
assignment_seed : ${ASSIGNMENT_SEED}
tigress_seed    : ${TIGRESS_SEED}
source_dir      : ${SOURCE_DIR}
files_dumped    : ${N_FILES}
obfuscated      : ${OK}
fallback        : ${FALLBACK}
transform_breakdown : ${BREAKDOWN}
build_status    : OK
EOF

echo "=== Source corpus for seed $ASSIGNMENT_SEED ready ==="
echo "    Obfuscated   : $OK  (fallback: $FALLBACK)"
echo "    Breakdown    : $BREAKDOWN"
echo "    Files dumped : $N_FILES"
echo "    Source dir   : $SOURCE_DIR"
echo "    Meta         : $META"

rm -f "$LOG"
