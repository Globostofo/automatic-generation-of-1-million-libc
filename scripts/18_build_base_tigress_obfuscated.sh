#!/bin/bash
# =============================================================================
# Script   : 18_build_base_tigress_obfuscated.sh
# Purpose  : Compile ONE obfuscated base for a given Tigress transform combo
#            (fixed seed -- --Seed= confirmed 2026-08-14 to not produce
#            meaningfully different .text bytes for Flatten/Split, only
#            internal symbol names change, so per-variant volume comes from
#            relinking, not from recompiling with a new seed -- see
#            19_/20_). Kept on disk (not deleted), with a .sections.txt file
#            for the layout-randomization relink step, same pattern as
#            12_build_base_random.sh but keyed by transform combo instead of
#            alignment flags.
# Usage    : ./scripts/18_build_base_tigress_obfuscated.sh <combo_id> <transform>
#            Example: ./scripts/18_build_base_tigress_obfuscated.sh flatten Flatten
#                      ./scripts/18_build_base_tigress_obfuscated.sh split Split
#                      ./scripts/18_build_base_tigress_obfuscated.sh flatten_split Flatten,Split
#            Env vars:
#              TIGRESS_EXTRA_ARGS   required, e.g. --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_BASE_SEED    fixed seed for the obfuscated compile (default: 1)
#              TIGRESS_EXCLUDES     e.g. src/malloc/mallocng/malloc.c, see
#                                   tigress_cc_wrapper.sh header
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <combo_id> <transform>"
    echo "Example: $0 flatten_split Flatten,Split"
    exit 1
fi

COMBO_ID="$1"
TRANSFORM="$2"

BASE_ID="tigress_$COMBO_ID"
BASE_BUILD_DIR="$BASE_DIR/tmp/base_$BASE_ID"
LOG="$RESULTS_DIR/base_$BASE_ID.build.log"
META="$RESULTS_DIR/base_$BASE_ID.meta.txt"
SECTIONS="$RESULTS_DIR/base_$BASE_ID.sections.txt"

export TIGRESS_PHASE=variant
export TIGRESS_SEED="${TIGRESS_BASE_SEED:-1}"
export REALCC="${REALCC:-gcc}"
export TIGRESS_TRANSFORM="$TRANSFORM"
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
export TIGRESS_TMP="$BASE_DIR/tmp/tigress_${BASE_ID}_scratch"
export TIGRESS_BASE_CACHE="$BASE_DIR/tmp/tigress_${BASE_ID}_cache"
export TIGRESS_REPORT="$RESULTS_DIR/base_$BASE_ID.tigress_report.txt"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

echo "=== Building obfuscated base $BASE_ID (transform: $TRANSFORM, seed $TIGRESS_SEED) ==="
echo "    Build : $BASE_BUILD_DIR (kept on disk, not deleted)"

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
combo_id    : ${COMBO_ID}
base_id     : ${BASE_ID}
transform   : ${TRANSFORM}
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
echo "Next: 19_build_variant_tigress_relink.sh <variant_id> $COMBO_ID <seed>"

rm -f "$LOG"
echo "    Build log deleted"
