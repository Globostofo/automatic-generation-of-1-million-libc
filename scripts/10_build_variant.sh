#!/bin/bash
# =============================================================================
# Script   : 10_build_variant.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build a single musl variant with the given compilation flags
# Usage    : ./scripts/10_build_variant.sh <variant_id> <cflags>
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 2 ]
then
    echo "Usage: $0 <variant_id> <cflags>"
    echo "Example: $0 001 \"-O2 -fno-inline\""
    exit 1
fi

VARIANT_ID="$1"
CFLAGS="$2"
BUILD_DIR="$BASE_DIR/tmp/build_$VARIANT_ID"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"
META="$RESULTS_DIR/$VARIANT_ID.meta.txt"

echo "=== Building variant $VARIANT_ID ==="
echo "    CFLAGS    : $CFLAGS"
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

    echo "Compiling $VARIANT_ID..."
    make lib/libc.so >> "$LOG" 2>&1

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
variant_id  : ${VARIANT_ID}
cflags      : ${CFLAGS}
libc_so     : ${LIBC_SO}
size_bytes  : ${SIZE}
sha256_full : ${SHA256}
sha256_text : ${TEXT_SHA256}
build_status: OK
EOF

echo "=== Variant $VARIANT_ID built successfully ==="
echo "    SHA256 (.text) : $TEXT_SHA256"
echo "    Taille         : $SIZE bytes"
echo "    Meta           : $META"

rm -f "$LOG"
echo "    Build log deleted"
