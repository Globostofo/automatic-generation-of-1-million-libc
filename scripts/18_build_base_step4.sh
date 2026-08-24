#!/bin/bash
# =============================================================================
# Script   : 18_build_base_step4.sh
# Purpose  : Step 4 (axis combination). Compile a single "base" build of musl
#            combining two axes: an already-obfuscated source tree (see
#            17_build_source_tigress.sh, one Tigress assignment seed = one
#            full corpus obfuscation pass, reused here across every flags
#            combo) and one of step 1's compiler flag combinations. The
#            obfuscated source is only ever obfuscated once per seed; this
#            script just recompiles it, so it's as cheap as step 1's own
#            base builds (no Tigress involved here at all).
#
#            Output layout intentionally matches 12_build_base_random.sh's
#            (tmp/base_<combo_id>/ + results/base_<combo_id>.sections.txt +
#            a meta.txt with the same "cflags"/"align_functions"/
#            "align_loops"/"align_jumps"/"align_labels" keys, even though
#            step 4 bases have no alignment jitter axis -- placeholder "n/a"
#            values keep the format grep-compatible) so that
#            13_build_variant_random.sh can relink it UNCHANGED for the
#            layout-randomization tier, exactly as it already does for step
#            2's own bases.
#
#            Setup cost: this runs once per (seed x flags combo) pair --
#            hundreds of times per campaign -- so the tree-copy step is
#            hardlinked (`cp -al`) instead of a real recursive copy of
#            musl's full source tree, then the obfuscated files are
#            overlaid with `--remove-destination` (breaks the hardlink per
#            file being overwritten instead of writing through the shared
#            inode, which would silently corrupt $MUSL_DIR and every other
#            combo's base -- verified with a sandboxed negative-control
#            test before relying on this). Measured ~5.3x faster on the
#            copy+overlay step alone (1.04s -> 0.19s per combo locally);
#            falls back to a real copy if hardlinking isn't possible (e.g.
#            a different filesystem for tmp/ than deps/musl).
# Usage    : ./scripts/18_build_base_step4.sh <combo_id> <assignment_seed> <cflags>
#            Example: ./scripts/18_build_base_step4.sh 1_0001 12345 "-O2 -finline-functions"
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <combo_id> <assignment_seed> <cflags>"
    exit 1
fi

COMBO_ID="$1"
ASSIGNMENT_SEED="$2"
CFLAGS="$3"

SOURCE_DIR="$BASE_DIR/tmp/obfuscated_$ASSIGNMENT_SEED"
BASE_BUILD_DIR="$BASE_DIR/tmp/base_$COMBO_ID"
LOG="$RESULTS_DIR/base_$COMBO_ID.build.log"
META="$RESULTS_DIR/base_$COMBO_ID.meta.txt"
SECTIONS="$RESULTS_DIR/base_$COMBO_ID.sections.txt"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "[ERROR] Obfuscated source tree not found: $SOURCE_DIR"
    echo "        Run 17_build_source_tigress.sh $ASSIGNMENT_SEED first."
    exit 1
fi

echo "=== Building step 4 base $COMBO_ID (seed $ASSIGNMENT_SEED) ==="
echo "    CFLAGS : $CFLAGS"
echo "    Build  : $BASE_BUILD_DIR"

rm -rf "$BASE_BUILD_DIR"
mkdir -p "$BASE_BUILD_DIR" "$RESULTS_DIR"

# Hardlink the pristine musl tree instead of copying it byte-for-byte --
# this build is one of potentially hundreds (seeds x flags combos) sharing
# the exact same $MUSL_DIR content, so a real recursive copy of thousands
# of files per combo adds up. `cp -al` (archive + link) makes every regular
# file in $BASE_BUILD_DIR a hardlink to the original inode instead of a
# fresh copy -- near-instant regardless of tree size. The overlay step
# below MUST use --remove-destination: without it, GNU cp overwrites an
# existing destination file's content in place, which would silently
# corrupt the shared inode (i.e. $MUSL_DIR itself and every other combo's
# base still linked to it) -- confirmed by a sandboxed negative-control
# test before relying on this. Falls back to a real recursive copy if
# hardlinking isn't possible (e.g. tmp/ on a different filesystem than
# deps/musl -- not the case in this repo layout, but not assumed either).
if ! cp -al "$MUSL_DIR/." "$BASE_BUILD_DIR/" 2>/dev/null; then
    echo "[WARN] Hardlink copy failed (different filesystem?), falling back to a real copy."
    rm -rf "$BASE_BUILD_DIR"
    mkdir -p "$BASE_BUILD_DIR"
    cp -r "$MUSL_DIR/." "$BASE_BUILD_DIR/"
fi
cp -r --remove-destination "$SOURCE_DIR/." "$BASE_BUILD_DIR/"

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
assignment_seed : ${ASSIGNMENT_SEED}
cflags          : ${CFLAGS}
align_functions : n/a
align_loops     : n/a
align_jumps     : n/a
align_labels    : n/a
sections_file   : ${SECTIONS}
n_sections      : ${N_SECTIONS}
build_status    : OK
EOF

echo "=== Base $COMBO_ID built successfully ==="
echo "    Sections found : $N_SECTIONS"
echo "    Meta           : $META"

rm -f "$LOG"
echo "    Build log deleted"
