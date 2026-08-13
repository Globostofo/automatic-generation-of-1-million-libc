#!/bin/bash
# =============================================================================
# Script   : 15_build_base_tigress.sh
# Purpose  : Warm the shared Tigress prep cache (reference-compile + preprocess
#            + [static N] fix + stub main for every eligible .c file) used by
#            16_build_variant_tigress.sh, so every subsequent variant build
#            skips that seed-independent work and only redoes the actual
#            Tigress transform + final compile. Unlike step 2's base (which
#            only needs compiling once since alignment is a compile-time-only
#            flag), step 3's per-variant work still needs a full recompile
#            per seed -- only the prep step is shared, not the compiled
#            objects themselves. As a side effect this also produces a real,
#            unobfuscated baseline build (installed as variants/tigress_base/)
#            to compare obfuscated variants against.
# Usage    : ./scripts/15_build_base_tigress.sh
#            Env vars:
#              TIGRESS_BASE_CACHE  shared cache dir (default: $BASE_DIR/tmp/tigress_base_cache)
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

VARIANT_ID="tigress_base"
BUILD_DIR="$BASE_DIR/tmp/build_$VARIANT_ID"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"

export TIGRESS_BASE_CACHE="${TIGRESS_BASE_CACHE:-$BASE_DIR/tmp/tigress_base_cache}"
export TIGRESS_PHASE=prep
export REALCC="${REALCC:-gcc}"
export TIGRESS_TMP="$BASE_DIR/tmp/tigress_prep_scratch"
export TIGRESS_REPORT="$RESULTS_DIR/$VARIANT_ID.tigress_report.txt"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

echo "=== Warming Tigress prep cache + building baseline ($VARIANT_ID) ==="
echo "    Cache     : $TIGRESS_BASE_CACHE"
echo "    Build     : $BUILD_DIR"

rm -rf "$VARIANT_DIR" "$TIGRESS_TMP" "$BUILD_DIR" "$TIGRESS_BASE_CACHE"
mkdir -p "$BUILD_DIR" "$VARIANT_LIB_DIR" "$RESULTS_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"
: > "$TIGRESS_REPORT"

cp -r "$MUSL_DIR/." "$BUILD_DIR/"

(
    cd "$BUILD_DIR"

    echo "Configuring $VARIANT_ID (CC=tigress_cc_wrapper.sh, TIGRESS_PHASE=prep)..."
    ./configure \
        --prefix="$VARIANT_DIR" \
        --syslibdir="$VARIANT_LIB_DIR" \
        CC="$SCRIPTS_DIR/tigress_cc_wrapper.sh" \
        >> "$LOG" 2>&1

    echo "Compiling $VARIANT_ID (running $MAKE_JOBS parallel jobs; unobfuscated, warms the cache)..."
    make -j"$MAKE_JOBS" lib/libc.so >> "$LOG" 2>&1

    echo "Installing $VARIANT_ID..."
    cp "$BUILD_DIR/lib/libc.so" "$VARIANT_LIB_DIR"
    ln -s libc.so "$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"
)

rm -rf "$BUILD_DIR"

LIBC_SO="$VARIANT_LIB_DIR/libc.so"
if [ ! -f "$LIBC_SO" ]; then
    echo "[ERROR] libc.so is missing after installation!"
    exit 1
fi

PREPOK=$(grep -c '^PREP-OK ' "$TIGRESS_REPORT" || true)
PREPFAIL=$(grep -c '^PREP-FALLBACK ' "$TIGRESS_REPORT" || true)

SIZE=$(stat -c%s "$LIBC_SO")
SHA256=$(sha256sum "$LIBC_SO" | awk '{print $1}')

cat > "$RESULTS_DIR/$VARIANT_ID.meta.txt" << EOF
variant_id  : ${VARIANT_ID}
libc_so     : ${LIBC_SO}
size_bytes  : ${SIZE}
sha256_full : ${SHA256}
cache_dir   : ${TIGRESS_BASE_CACHE}
prep_ok     : ${PREPOK}
prep_failed : ${PREPFAIL}
build_status: OK
EOF

echo ""
echo "=== Base ready ==="
echo "    Prep cache populated for : $PREPOK files ($PREPFAIL fell back, see $TIGRESS_REPORT)"
echo "    Baseline libc.so         : $LIBC_SO"
echo "Next: 16_build_variant_tigress.sh <variant_id> <seed>, reusing this cache."

rm -f "$LOG"
echo "    Build log deleted"
