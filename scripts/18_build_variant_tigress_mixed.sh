#!/bin/bash
# =============================================================================
# Script   : 18_build_variant_tigress_mixed.sh
# Purpose  : Build a single musl variant obfuscated with a per-file random
#            transform assignment instead of one fixed transform for the
#            whole corpus. Each eligible .c file independently gets one of
#            5 already-validated transforms (Flatten, Split, Flatten,Split,
#            Copy, AntiTaintAnalysis), deterministically picked from a hash
#            of (assignment_seed, file path) by tigress_cc_wrapper.sh --
#            see its TIGRESS_ASSIGNMENT_SEED handling.
#
#            No relink step, deliberately: this campaign exists specifically
#            to measure Tigress/obfuscation's own diversity contribution,
#            isolated from step 2's layout-randomization mechanism (which
#            was found to supply all of the previous K-fixed-combo
#            campaign's volume/duplication-avoidance on its own -- see
#            docs/step3_design.md). Every variant here is therefore its own
#            full corpus compile, not a cheap relink of a shared base --
#            real cost, not a bug: the whole point is that CHANGING the
#            per-file assignment is what's supposed to produce diversity,
#            so there is nothing left to safely share between variants
#            beyond the seed-independent prep work tigress_cc_wrapper.sh
#            already caches (reference-compile/preprocess/stub-main),
#            which still applies here if TIGRESS_BASE_CACHE is shared
#            across variants (recommended, see the campaign script).
# Usage    : ./scripts/18_build_variant_tigress_mixed.sh <variant_id> <assignment_seed>
#            Env vars:
#              TIGRESS_EXTRA_ARGS   required, e.g. --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_SEED         Tigress's own --Seed=, fixed (default: 1)
#                                   -- confirmed not to affect compiled
#                                   output for these transforms, kept fixed
#                                   rather than varied on top of the
#                                   per-file assignment
#              TIGRESS_EXCLUDES     e.g. src/malloc/mallocng/malloc.c, see
#                                   tigress_cc_wrapper.sh header
#              TIGRESS_BASE_CACHE   shared prep cache dir, reused across
#                                   variants (default: $BASE_DIR/tmp/tigress_mixed_cache)
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <variant_id> <assignment_seed>"
    exit 1
fi

VARIANT_ID="$1"
ASSIGNMENT_SEED="$2"

BUILD_DIR="$BASE_DIR/tmp/build_tigress_mixed_$VARIANT_ID"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"

export TIGRESS_PHASE=variant
export TIGRESS_ASSIGNMENT_SEED="$ASSIGNMENT_SEED"
export TIGRESS_SEED="${TIGRESS_SEED:-1}"
export REALCC="${REALCC:-gcc}"
export TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:?fill with the tigress flags validated at palier 4, e.g. --Environment=x86_64:Linux:Gcc:4.6}"
export TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"
export TIGRESS_TMP="$BASE_DIR/tmp/tigress_mixed_${VARIANT_ID}_scratch"
export TIGRESS_BASE_CACHE="${TIGRESS_BASE_CACHE:-$BASE_DIR/tmp/tigress_mixed_cache}"
export TIGRESS_OUTPUT_CACHE="${TIGRESS_OUTPUT_CACHE-$BASE_DIR/tmp/tigress_mixed_output_cache}"
[ -n "$TIGRESS_OUTPUT_CACHE" ] && mkdir -p "$TIGRESS_OUTPUT_CACHE"
export TIGRESS_REPORT="$RESULTS_DIR/$VARIANT_ID.tigress_report.txt"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

echo "=== Building mixed-assignment variant $VARIANT_ID (assignment seed $ASSIGNMENT_SEED) ==="

rm -rf "$VARIANT_DIR" "$TIGRESS_TMP" "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$VARIANT_LIB_DIR" "$RESULTS_DIR" "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"
: > "$TIGRESS_REPORT"

cp -r "$MUSL_DIR/." "$BUILD_DIR/"

(
    cd "$BUILD_DIR"

    ./configure \
        --prefix="$VARIANT_DIR" \
        --syslibdir="$VARIANT_LIB_DIR" \
        CC="$SCRIPTS_DIR/tigress_cc_wrapper.sh" \
        >> "$LOG" 2>&1

    echo "Compiling $VARIANT_ID (running $MAKE_JOBS parallel jobs, per-file random transform assignment)..."
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

# Per-transform breakdown of this variant's actual assignment (how many
# eligible files landed on each of the 5 transforms) -- useful for sanity
# checks and for the report, without needing to re-derive it from the raw
# per-file report lines each time.
BREAKDOWN=$(awk '$1=="OK"{print $3}' "$TIGRESS_REPORT" | sort | uniq -c | sort -rn | awk '{printf "%s:%s ", $2, $1}')

cat > "$RESULTS_DIR/$VARIANT_ID.meta.txt" << EOF
variant_id      : ${VARIANT_ID}
assignment_seed : ${ASSIGNMENT_SEED}
tigress_seed    : ${TIGRESS_SEED}
libc_so         : ${LIBC_SO}
size_bytes      : ${SIZE}
sha256_full     : ${SHA256}
sha256_text     : ${TEXT_SHA256}
obfuscated      : ${OK}
fallback        : ${FALLBACK}
transform_breakdown : ${BREAKDOWN}
build_status    : OK
EOF

echo "=== Variant $VARIANT_ID built ==="
echo "    Obfuscated     : $OK  (fallback: $FALLBACK)"
echo "    Breakdown      : $BREAKDOWN"
echo "    SHA256 (.text) : $TEXT_SHA256"
echo "    Meta           : $RESULTS_DIR/$VARIANT_ID.meta.txt"

rm -f "$LOG"
