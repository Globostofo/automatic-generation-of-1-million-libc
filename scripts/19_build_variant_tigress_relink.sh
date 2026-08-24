#!/bin/bash
# =============================================================================
# Script   : 19_build_variant_tigress_relink.sh
# Purpose  : Build a single variant by relinking an already-built obfuscated
#            base (see 18_build_base_tigress_obfuscated.sh) for a given
#            transform combo, with a random function order and zero-filled
#            padding gaps (step 2's proven mechanism, 0% duplication measured
#            there) -- instead of recompiling with a new Tigress seed
#            (confirmed to add no real diversity, see 18_'s header). Only the
#            link step is redone per variant; the expensive Tigress
#            transform is shared by every variant of the same combo.
# Usage    : ./scripts/19_build_variant_tigress_relink.sh <variant_id> <combo_id> <seed> [pad_min] [pad_max]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <variant_id> <combo_id> <seed> [pad_min] [pad_max]"
    exit 1
fi

VARIANT_ID="$1"
COMBO_ID="$2"
SEED="$3"
PAD_MIN="${4:-0}"
PAD_MAX="${5:-64}"

BASE_ID="tigress_$COMBO_ID"
BASE_BUILD_DIR="$BASE_DIR/tmp/base_$BASE_ID"
BASE_META="$RESULTS_DIR/base_$BASE_ID.meta.txt"
BASE_SECTIONS="$RESULTS_DIR/base_$BASE_ID.sections.txt"
LOCK="$BASE_BUILD_DIR/.relink.lock"

if [ ! -d "$BASE_BUILD_DIR" ] || [ ! -f "$BASE_SECTIONS" ]; then
    echo "[ERROR] Obfuscated base $BASE_ID not found. Run 18_build_base_tigress_obfuscated.sh $COMBO_ID first."
    exit 1
fi

VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"
META="$RESULTS_DIR/$VARIANT_ID.meta.txt"
ORDER_SCRIPT="$RESULTS_DIR/$VARIANT_ID.order.ld"

echo "=== Building variant $VARIANT_ID (base $BASE_ID, relink seed $SEED) ==="

rm -rf "$VARIANT_DIR"
mkdir -p "$VARIANT_LIB_DIR" "$RESULTS_DIR"

python3 "$SCRIPTS_DIR/gen_order_script.py" "$SEED" "$PAD_MIN" "$PAD_MAX" \
    < "$BASE_SECTIONS" \
    > "$ORDER_SCRIPT"

# Serialized per base via flock since several variants may relink the same
# base concurrently -- same pattern as 13_build_variant_random.sh.
(
    flock 9

    cd "$BASE_BUILD_DIR"
    rm -f lib/libc.so
    make lib/libc.so LDFLAGS="-Wl,-T,$ORDER_SCRIPT" >> "$LOG" 2>&1
    cp lib/libc.so "$VARIANT_LIB_DIR/libc.so"
) 9> "$LOCK"

ln -s libc.so "$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"

LIBC_SO="$VARIANT_LIB_DIR/libc.so"
if [ ! -f "$LIBC_SO" ]; then
    echo "[ERROR] libc.so is missing after installation!"
    exit 1
fi

SIZE=$(stat -c%s "$LIBC_SO")
SHA256=$(sha256sum "$LIBC_SO" | awk '{print $1}')
TEXT_SHA256=$(objcopy --only-section=.text "$LIBC_SO" /tmp/text_$$.bin 2> /dev/null \
              && sha256sum /tmp/text_$$.bin | awk '{print $1}'; rm -f /tmp/text_$$.bin)

TRANSFORM=$(grep "^transform" "$BASE_META" | awk -F': ' '{print $2}')
TIGRESS_SEED_USED=$(grep "^seed" "$BASE_META" | awk -F': ' '{print $2}')

cat > "$META" << EOF
variant_id      : ${VARIANT_ID}
combo_id        : ${COMBO_ID}
base_id         : ${BASE_ID}
transform       : ${TRANSFORM}
tigress_seed    : ${TIGRESS_SEED_USED}
relink_seed     : ${SEED}
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
echo "    Meta           : $META"

rm -f "$LOG"
