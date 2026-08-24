#!/bin/bash
# =============================================================================
# Script   : 18_build_base_tigress_obfuscated.sh
# Purpose  : URGENT FALLBACK for step 3's diversity axis. Discovered
#            2026-08-14: Tigress's --Seed= with Flatten+Split does NOT
#            produce meaningfully different .text bytes between seeds (only
#            internal symbol names differ, confirmed via full disassembly
#            diff -- a full campaign of 20 "different-seed" variants came
#            back byte-identical). Recompiling per seed is also expensive
#            (real Tigress invocations) for zero benefit.
#            Pragmatic fix, pulled forward from step 4's axis-combination
#            idea: compile ONE obfuscated base (fixed seed, kept on disk,
#            not deleted like 15_/16_ do), then generate real diversity by
#            relinking it with step 2's proven layout-randomization
#            mechanism (function order + padding, 0% duplication measured
#            in step 2) via 19_build_variant_tigress_relink.sh. The
#            obfuscation transform itself is fixed across all variants; the
#            diversity comes from layout, same as step 2.
# Usage    : ./scripts/18_build_base_tigress_obfuscated.sh
#            Env vars:
#              TIGRESS_EXTRA_ARGS   required, e.g. --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_TRANSFORM    default: Flatten,Split
#              TIGRESS_BASE_SEED    fixed seed for the one obfuscated
#                                   compile (default: 1) -- NOT varied here,
#                                   diversity comes from the relink step
#              TIGRESS_EXCLUDES     e.g. src/malloc/mallocng/malloc.c, see
#                                   tigress_cc_wrapper.sh header
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

BASE_ID="tigress_obf"
BASE_BUILD_DIR="$BASE_DIR/tmp/base_$BASE_ID"
LOG="$RESULTS_DIR/base_$BASE_ID.build.log"
META="$RESULTS_DIR/base_$BASE_ID.meta.txt"
SECTIONS="$RESULTS_DIR/base_$BASE_ID.sections.txt"

export TIGRESS_PHASE=variant
export TIGRESS_SEED="${TIGRESS_BASE_SEED:-1}"
export REALCC="${REALCC:-gcc}"
export TIGRESS_TRANSFORM="${TIGRESS_TRANSFORM:-Flatten,Split}"
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
export TIGRESS_TMP="$BASE_DIR/tmp/tigress_base_obf_scratch"
export TIGRESS_BASE_CACHE="$BASE_DIR/tmp/tigress_base_obf_cache"
export TIGRESS_REPORT="$RESULTS_DIR/base_$BASE_ID.tigress_report.txt"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

echo "=== Building ONE obfuscated base ($BASE_ID, fixed seed $TIGRESS_SEED) ==="
echo "    Transform : $TIGRESS_TRANSFORM"
echo "    Build     : $BASE_BUILD_DIR (kept on disk, not deleted)"

rm -rf "$BASE_BUILD_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"
mkdir -p "$BASE_BUILD_DIR" "$RESULTS_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"
: > "$TIGRESS_REPORT"

cp -r "$MUSL_DIR/." "$BASE_BUILD_DIR/"

(
    cd "$BASE_BUILD_DIR"

    echo "Configuring $BASE_ID (CC=tigress_cc_wrapper.sh)..."
    ./configure \
        --prefix="$BASE_BUILD_DIR/install" \
        --syslibdir="$BASE_BUILD_DIR/install/lib" \
        CC="$SCRIPTS_DIR/tigress_cc_wrapper.sh" \
        >> "$LOG" 2>&1

    echo "Compiling $BASE_ID (running $MAKE_JOBS parallel jobs, this runs Tigress once per file)..."
    make -j"$MAKE_JOBS" lib/libc.so >> "$LOG" 2>&1
)

echo "Enumerating .text.* sections for base $BASE_ID..."
OBJECTS=$(find "$BASE_BUILD_DIR/obj" -name "*.lo")
readelf -S --wide $OBJECTS 2> /dev/null \
    | grep -oP '\.text\.\S+' \
    | sort -u \
    > "$SECTIONS"

N_SECTIONS=$(wc -l < "$SECTIONS")
OK=$(grep -c '^OK ' "$TIGRESS_REPORT" || true)
FALLBACK=$(grep -c '^FALLBACK ' "$TIGRESS_REPORT" || true)

cat > "$META" << EOF
base_id     : ${BASE_ID}
transform   : ${TIGRESS_TRANSFORM}
seed        : ${TIGRESS_SEED}
obfuscated  : ${OK}
fallback    : ${FALLBACK}
sections_file : ${SECTIONS}
n_sections  : ${N_SECTIONS}
build_status: OK
EOF

echo "=== Base $BASE_ID built successfully ==="
echo "    Obfuscated     : $OK  (fallback: $FALLBACK)"
echo "    Sections found : $N_SECTIONS"
echo "    Meta           : $META"
echo "Next: 19_build_variant_tigress_relink.sh <variant_id> <seed>"

rm -f "$LOG"
echo "    Build log deleted"
