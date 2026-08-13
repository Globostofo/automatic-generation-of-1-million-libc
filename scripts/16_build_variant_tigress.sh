#!/bin/bash
# =============================================================================
# Script   : 16_build_variant_tigress.sh
# Purpose  : Build a single Tigress-obfuscated musl variant for a given seed,
#            reusing the shared prep cache from 15_build_base_tigress.sh
#            (reference-compile/preprocess/[static N] fix/stub main are
#            identical across every variant of a file -- only the actual
#            Tigress transform depends on the seed, so only that + the final
#            compile are redone here). Requires 15_build_base_tigress.sh to
#            have been run at least once first.
# Usage    : ./scripts/16_build_variant_tigress.sh <variant_id> <seed>
#            Env vars:
#              TIGRESS_BASE_CACHE  must match what 15_build_base_tigress.sh used
#              TIGRESS_TRANSFORM   comma-separated --Transform= chain (default: Flatten,Split)
#              TIGRESS_EXTRA_ARGS  e.g. --Environment=x86_64:Linux:Gcc:4.6 (required)
#              TIGRESS_EXCLUDES    file of source paths to always leave unobfuscated
#                                  (recommend keeping src/malloc/mallocng/malloc.c
#                                  excluded, see tigress_cc_wrapper.sh header)
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <variant_id> <seed>"
    exit 1
fi

VARIANT_ID="$1"
SEED="$2"

BUILD_DIR="$BASE_DIR/tmp/build_$VARIANT_ID"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"

export TIGRESS_BASE_CACHE="${TIGRESS_BASE_CACHE:-$BASE_DIR/tmp/tigress_base_cache}"
if [ ! -d "$TIGRESS_BASE_CACHE" ] || [ -z "$(ls -A "$TIGRESS_BASE_CACHE" 2> /dev/null)" ]; then
    echo "[ERROR] Prep cache not found/empty at $TIGRESS_BASE_CACHE. Run 15_build_base_tigress.sh first."
    exit 1
fi

export TIGRESS_PHASE=variant
export TIGRESS_SEED="$SEED"
export REALCC="${REALCC:-gcc}"
export TIGRESS_TRANSFORM="${TIGRESS_TRANSFORM:-Flatten,Split}"
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_TMP="$BASE_DIR/tmp/tigress_$VARIANT_ID"
export TIGRESS_REPORT="$RESULTS_DIR/$VARIANT_ID.tigress_report.txt"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

echo "=== Building Tigress variant $VARIANT_ID (seed $SEED) ==="
echo "    Transform : $TIGRESS_TRANSFORM"
echo "    Cache     : $TIGRESS_BASE_CACHE"

rm -rf "$VARIANT_DIR" "$TIGRESS_TMP" "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$VARIANT_LIB_DIR" "$RESULTS_DIR" "$TIGRESS_TMP"
: > "$TIGRESS_REPORT"

cp -r "$MUSL_DIR/." "$BUILD_DIR/"

(
    cd "$BUILD_DIR"

    ./configure \
        --prefix="$VARIANT_DIR" \
        --syslibdir="$VARIANT_LIB_DIR" \
        CC="$SCRIPTS_DIR/tigress_cc_wrapper.sh" \
        >> "$LOG" 2>&1

    echo "Compiling $VARIANT_ID (running $MAKE_JOBS parallel jobs, reusing cached prep)..."
    make -j"$MAKE_JOBS" lib/libc.so >> "$LOG" 2>&1

    cp "$BUILD_DIR/lib/libc.so" "$VARIANT_LIB_DIR"
    ln -s libc.so "$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"
)

rm -rf "$BUILD_DIR"

LIBC_SO="$VARIANT_LIB_DIR/libc.so"
if [ ! -f "$LIBC_SO" ]; then
    echo "[ERROR] libc.so is missing after installation!"
    exit 1
fi

OK=$(grep -c '^OK ' "$TIGRESS_REPORT" || true)
FALLBACK=$(grep -c '^FALLBACK ' "$TIGRESS_REPORT" || true)
SIZE=$(stat -c%s "$LIBC_SO")
SHA256=$(sha256sum "$LIBC_SO" | awk '{print $1}')
TEXT_SHA256=$(objcopy --only-section=.text "$LIBC_SO" /tmp/text_$$.bin 2> /dev/null \
              && sha256sum /tmp/text_$$.bin | awk '{print $1}'; rm -f /tmp/text_$$.bin)

cat > "$RESULTS_DIR/$VARIANT_ID.meta.txt" << EOF
variant_id  : ${VARIANT_ID}
seed        : ${SEED}
transform   : ${TIGRESS_TRANSFORM}
libc_so     : ${LIBC_SO}
size_bytes  : ${SIZE}
sha256_full : ${SHA256}
sha256_text : ${TEXT_SHA256}
obfuscated  : ${OK}
fallback    : ${FALLBACK}
build_status: OK
EOF

echo "=== Variant $VARIANT_ID built ==="
echo "    Obfuscated     : $OK  (fallback: $FALLBACK)"
echo "    SHA256 (.text) : $TEXT_SHA256"
echo "    Meta           : $RESULTS_DIR/$VARIANT_ID.meta.txt"

rm -f "$LOG"
