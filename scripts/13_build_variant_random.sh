#!/bin/bash
# =============================================================================
# Script   : 13_build_variant_random.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build a single musl variant by relinking an already-compiled
#            base build (see 12_build_base_random.sh) with a random function
#            order and zero-filled padding gaps derived from a seed. Only the link
#            step is redone per variant; compilation is shared across every
#            variant built from the same alignment combo.
# Usage    : ./scripts/13_build_variant_random.sh <variant_id> <combo_id> <seed> [pad_min] [pad_max]
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 3 ]
then
    echo "Usage: $0 <variant_id> <combo_id> <seed> [pad_min] [pad_max]"
    echo "Example: $0 0001 001 12345"
    exit 1
fi

VARIANT_ID="$1"
COMBO_ID="$2"
SEED="$3"
PAD_MIN="${4:-0}"
PAD_MAX="${5:-64}"

BASE_BUILD_DIR="$BASE_DIR/tmp/base_$COMBO_ID"
BASE_META="$RESULTS_DIR/base_$COMBO_ID.meta.txt"
BASE_SECTIONS="$RESULTS_DIR/base_$COMBO_ID.sections.txt"
LOCK="$BASE_BUILD_DIR/.relink.lock"

if [ ! -d "$BASE_BUILD_DIR" ] || [ ! -f "$BASE_SECTIONS" ]
then
    echo "[ERROR] Base build $COMBO_ID not found. Run 12_build_base_random.sh $COMBO_ID first."
    exit 1
fi

VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LOG="$RESULTS_DIR/$VARIANT_ID.build.log"
META="$RESULTS_DIR/$VARIANT_ID.meta.txt"
ORDER_SCRIPT="$RESULTS_DIR/$VARIANT_ID.order.ld"

echo "=== Building variant $VARIANT_ID (base $COMBO_ID, seed $SEED) ==="

rm -rf "$VARIANT_DIR"
mkdir -p "$VARIANT_LIB_DIR" "$RESULTS_DIR"

python3 "$SCRIPTS_DIR/gen_order_script.py" "$SEED" "$PAD_MIN" "$PAD_MAX" \
    < "$BASE_SECTIONS" \
    > "$ORDER_SCRIPT"

# The base build directory is shared by every variant of this combo: several
# 13_ instances may relink it concurrently (different seeds, same combo), so
# the relink itself is serialized per combo via flock. Relinking is cheap
# (seconds), so this doesn't hurt throughput as long as there are enough
# combos to keep all parallel jobs busy on other combos meanwhile.
(
    flock 9

    cd "$BASE_BUILD_DIR"
    rm -f lib/libc.so
    make lib/libc.so LDFLAGS="-Wl,-T,$ORDER_SCRIPT" >> "$LOG" 2>&1
    cp lib/libc.so "$VARIANT_LIB_DIR/libc.so"
) 9> "$LOCK"

ln -s libc.so "$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"

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

CFLAGS=$(grep "cflags" "$BASE_META" | awk -F': ' '{print $2}')
ALIGN_FUNCTIONS=$(grep "align_functions" "$BASE_META" | awk '{print $3}')
ALIGN_LOOPS=$(grep "align_loops" "$BASE_META" | awk '{print $3}')
ALIGN_JUMPS=$(grep "align_jumps" "$BASE_META" | awk '{print $3}')
ALIGN_LABELS=$(grep "align_labels" "$BASE_META" | awk '{print $3}')

cat > "$META" << EOF
variant_id      : ${VARIANT_ID}
combo_id        : ${COMBO_ID}
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
