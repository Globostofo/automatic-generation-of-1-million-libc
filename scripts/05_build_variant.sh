#!/bin/bash
# =============================================================================
# Script   : 05_build_variant.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build a single musl variant with the given compilation flags
# Usage    : ./scripts/05_build_variant.sh <variant_id> <cflags>
# =============================================================================

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSL_SRC="$BASE_DIR/deps/musl"

if [ "$#" -lt 2 ]
then
    echo "Usage: $0 <variant_id> <cflags>"
    echo "Example: $0 001 \"-O2 -fno-inline\""
    exit 1
fi

VARIANT_ID="$1"
CFLAGS="$2"
PREFIX="$BASE_DIR/variants/${VARIANT_ID}"
LOG="$BASE_DIR/results/${VARIANT_ID}.build.log"
META="$BASE_DIR/results/${VARIANT_ID}.meta.txt"

echo "=== Build variant ${VARIANT_ID}==="
echo "    CFLAGS : ${CFLAGS}"
echo "    Prefix : ${PREFIX}"

rm -rf "$PREFIX"

cd $MUSL_SRC
make clean

echo "[1/3] Configure..."
./configure \
    --prefix="$PREFIX" \
    --syslibdir="$PREFIX/lib" \
    CFLAGS="$CFLAGS" \
    >> "$LOG" 2>&1

echo "[2/3] Build..."
make -j$(nproc) >> "$LOG" 2>&1

echo "[3/3] Install..."
make install >> "$LOG" 2>&1

LIBC_SO="$PREFIX/lib/libc.so"
if [ ! -f "$LIBC_SO" ]
then
    echo "[ERROR] libc.so is missing after installation!"
    exit 1
fi

TIMESTAMP=$(date -Iseconds)
SIZE=$(stat -c%s "$LIBC_SO")
SHA256=$(sha256sum "$LIBC_SO" | awk '{print $1}')
TEXT_SHA256=$(objcopy --only-section=.text "$LIBC_SO" /tmp/text_$$.bin 2> /dev/null \
              && sha256sum /tmp/text_$$.bin | awk '{print $1}'; rm -f /tmp/text_$$.bin)

cat > "$META" << EOF
variant_id  : ${VARIANT_ID}
timestamp   : ${TIMESTAMP}
cflags      : ${CFLAGS}
libc_so     : ${LIBC_SO}
size_bytes  : ${SIZE}
sha256_full : ${SHA256}
sha256_text : ${TEXT_SHA256}
build_status: OK
EOF

echo "=== Variant ${VARIANT_ID} compiled successfully ==="
echo "    SHA256 (.text) : ${TEXT_SHA256}"
echo "    Taille         : ${SIZE} bytes"
echo "    Meta           : ${META}"
