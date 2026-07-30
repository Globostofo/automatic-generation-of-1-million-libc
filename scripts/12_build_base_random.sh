#!/bin/bash
# =============================================================================
# Script   : 12_build_base_random.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Compile a single "base" build of musl for one alignment
#            combination (-O2 + alignment jitter). The build is kept on disk
#            (tmp/base_<combo_id>/) and reused by 13_build_variant_random.sh
#            to relink many variants (one per seed) without recompiling,
#            since compilation only depends on the alignment flags, not on
#            the function order/padding seed.
# Usage    : ./scripts/12_build_base_random.sh <combo_id> <align_functions> <align_loops> <align_jumps> <align_labels>
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 5 ]
then
    echo "Usage: $0 <combo_id> <align_functions> <align_loops> <align_jumps> <align_labels>"
    echo "Example: $0 001 16 8 4 1"
    exit 1
fi

COMBO_ID="$1"
ALIGN_FUNCTIONS="$2"
ALIGN_LOOPS="$3"
ALIGN_JUMPS="$4"
ALIGN_LABELS="$5"

BASE_BUILD_DIR="$BASE_DIR/tmp/base_$COMBO_ID"
LOG="$RESULTS_DIR/base_$COMBO_ID.build.log"
META="$RESULTS_DIR/base_$COMBO_ID.meta.txt"
SECTIONS="$RESULTS_DIR/base_$COMBO_ID.sections.txt"

CFLAGS="-O2 -ffunction-sections -falign-functions=$ALIGN_FUNCTIONS -falign-loops=$ALIGN_LOOPS -falign-jumps=$ALIGN_JUMPS -falign-labels=$ALIGN_LABELS"

echo "=== Building base $COMBO_ID ==="
echo "    CFLAGS : $CFLAGS"
echo "    Build  : $BASE_BUILD_DIR"

rm -rf "$BASE_BUILD_DIR"
mkdir -p "$BASE_BUILD_DIR" "$RESULTS_DIR"

cp -r "$MUSL_DIR/." "$BASE_BUILD_DIR/"

(
    cd "$BASE_BUILD_DIR"

    echo "Configuring base $COMBO_ID..."
    ./configure \
        --prefix="$BASE_BUILD_DIR/install" \
        --syslibdir="$BASE_BUILD_DIR/install/lib" \
        CFLAGS="$CFLAGS" \
        >> "$LOG" 2>&1

    echo "Compiling base $COMBO_ID..."
    make lib/libc.so >> "$LOG" 2>&1
)

echo "Enumerating .text.* sections for base $COMBO_ID..."
OBJECTS=$(find "$BASE_BUILD_DIR/obj" -name "*.lo")
readelf -S --wide $OBJECTS 2> /dev/null \
    | grep -oP '\.text\.\S+' \
    | sort -u \
    > "$SECTIONS"

N_SECTIONS=$(wc -l < "$SECTIONS")

cat > "$META" << EOF
combo_id        : ${COMBO_ID}
cflags          : ${CFLAGS}
align_functions : ${ALIGN_FUNCTIONS}
align_loops     : ${ALIGN_LOOPS}
align_jumps     : ${ALIGN_JUMPS}
align_labels    : ${ALIGN_LABELS}
sections_file   : ${SECTIONS}
n_sections      : ${N_SECTIONS}
build_status    : OK
EOF

echo "=== Base $COMBO_ID built successfully ==="
echo "    Sections found : $N_SECTIONS"
echo "    Meta           : $META"

rm -f "$LOG"
echo "    Build log deleted"
