#!/bin/bash
# =============================================================================
# Script   : 13_build_variant_random.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build a single musl variant with a fixed base optimization level
#            (-O2) and randomized layout: alignment jitter (compile-time) plus
#            a random function order and NOP padding gaps (link-time), driven
#            by a single seed. Isolates the "compiler/link-level layout
#            randomization" axis from the flags axis explored in step 1.
# Usage    : ./scripts/13_build_variant_random.sh <variant_id> <align_functions> \
#              <align_loops> <align_jumps> <align_labels> <seed> [pad_min] [pad_max]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 6 ]
then
    echo "Usage: $0 <variant_id> <align_functions> <align_loops> <align_jumps> <align_labels> <seed> [pad_min] [pad_max]"
    echo "Example: $0 0001 16 8 4 1 12345"
    exit 1
fi

VARIANT_ID="$1"
ALIGN_FUNCTIONS="$2"
ALIGN_LOOPS="$3"
ALIGN_JUMPS="$4"
ALIGN_LABELS="$5"
SEED="$6"
PAD_MIN="${7:-0}"
PAD_MAX="${8:-64}"

BUILD_DIR="$BASE_DIR/tmp/build_$VARIANT_ID"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"
META="$RESULTS_DIR/$VARIANT_ID.meta.txt"
ORDER_SCRIPT="$RESULTS_DIR/$VARIANT_ID.order.ld"

CFLAGS="-O2 -ffunction-sections -falign-functions=$ALIGN_FUNCTIONS -falign-loops=$ALIGN_LOOPS -falign-jumps=$ALIGN_JUMPS -falign-labels=$ALIGN_LABELS"

echo "=== Building variant $VARIANT_ID (randomized layout) ==="
echo "    CFLAGS    : $CFLAGS"
echo "    Seed      : $SEED (padding $PAD_MIN-$PAD_MAX bytes)"
echo "    Build     : $BUILD_DIR"
echo "    Directory : $VARIANT_DIR"

rm -rf "$VARIANT_DIR"
mkdir -p "$BUILD_DIR" "$VARIANT_LIB_DIR" "$RESULTS_DIR"

cp -r "$MUSL_DIR/." "$BUILD_DIR/"

(
    cd "$BUILD_DIR"

    echo "Configuring $VARIANT_ID..."
    ./configure \
        --prefix="$VARIANT_DIR" \
        --syslibdir="$VARIANT_LIB_DIR" \
        CFLAGS="$CFLAGS" \
        >> "$LOG" 2>&1

    echo "Compiling $VARIANT_ID (default layout, to obtain the .o files)..."
    make lib/libc.so >> "$LOG" 2>&1
)

echo "Enumerating .text.* sections for $VARIANT_ID..."
OBJECTS=$(find "$BUILD_DIR/obj" -name "*.o")
readelf -S --wide $OBJECTS 2> /dev/null \
    | grep -oP '\.text\.\S+' \
    | sort -u \
    | python3 "$SCRIPTS_DIR/gen_order_script.py" "$SEED" "$PAD_MIN" "$PAD_MAX" \
    > "$ORDER_SCRIPT"

(
    cd "$BUILD_DIR"

    echo "Relinking $VARIANT_ID with randomized layout..."
    rm -f lib/libc.so
    make lib/libc.so LDFLAGS="-Wl,-T,$ORDER_SCRIPT" >> "$LOG" 2>&1

    echo "Installing $VARIANT_ID..."
    cp "$BUILD_DIR/lib/libc.so" "$VARIANT_LIB_DIR"
    ln -s libc.so "$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"
)

rm -rf "$BUILD_DIR"

LIBC_SO="$VARIANT_LIB_DIR/libc.so"
if [ ! -f "$LIBC_SO" ]
then
    echo "[ERROR] libc.so is missing after installation!"
    exit 1
fi

SIZE=$(stat -c%s "$LIBC_SO")
SHA256=$(sha256sum "$LIBC_SO" | awk '{print $1}')
TEXT_SHA256=$(objcopy --only-section=.text "$LIBC_SO" /tmp/text_$$.bin 2> /dev/null \
              && sha256sum /tmp/text_$$.bin | awk '{print $1}'; rm -f /tmp/text_$$.bin)

cat > "$META" << EOF
variant_id      : ${VARIANT_ID}
cflags          : ${CFLAGS}
align_functions : ${ALIGN_FUNCTIONS}
align_loops     : ${ALIGN_LOOPS}
align_jumps     : ${ALIGN_JUMPS}
align_labels    : ${ALIGN_LABELS}
seed            : ${SEED}
pad_min         : ${PAD_MIN}
pad_max         : ${PAD_MAX}
order_script    : ${ORDER_SCRIPT}
libc_so         : ${LIBC_SO}
size_bytes      : ${SIZE}
sha256_full     : ${SHA256}
sha256_text     : ${TEXT_SHA256}
build_status    : OK
EOF

echo "=== Variant $VARIANT_ID built successfully ==="
echo "    SHA256 (.text) : $TEXT_SHA256"
echo "    Taille         : $SIZE bytes"
echo "    Meta           : $META"

rm -f "$LOG"
echo "    Build log deleted"
