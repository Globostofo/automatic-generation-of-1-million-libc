#!/bin/bash
# =============================================================================
# Script   : 99_clean_variants.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Clean generated variants and results
# Usage    : ./scripts/99_clean_variants.sh
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

echo "WARNING: This will delete all generated variants and results."
echo "         The toolchain and test binaries will be preserved."
echo ""
read -p "Are you sure? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]
then
    echo "Aborted."
    exit 0
fi

for dir in "$RESULTS_DIR" "$VARIANTS_DIR"
do
    if [ -z "$(ls -A "$dir" | grep -v '^\.' | grep -v 'toolchain.test.txt')" ]
    then
        echo "$(basename "$dir")/ already empty"
    else
        find "$dir" -mindepth 1 ! -name ".gitkeep" ! -name "toolchain.test.txt" -delete
        echo "$(basename "$dir")/ cleared"
    fi
done

if compgen -G "$BASE_DIR/tmp/base_*" > /dev/null
then
    rm -rf "$BASE_DIR"/tmp/base_*
    echo "tmp/base_* (step 2/4 base builds) cleared"
fi

# tmp/source_tigress_source_cache is deliberately excluded: it's the
# cross-campaign Tigress SOURCE cache (keyed including a hash of musl's own
# source content, so a stale entry misses cleanly rather than being served
# incorrectly) -- meant to persist and keep paying off across separate
# campaign runs, self-bounding in size (~720MB ceiling) regardless. Every
# other tmp/source_tigress_* entry (per-seed prep caches/scratch dirs, the
# shared prep cache) is safe and cheap to rebuild, so still cleared here.
if compgen -G "$BASE_DIR/tmp/obfuscated_*" > /dev/null || compgen -G "$BASE_DIR/tmp/build_source_tigress_*" > /dev/null || find "$BASE_DIR/tmp" -maxdepth 1 -name 'source_tigress_*' ! -name 'source_tigress_source_cache' -print -quit 2> /dev/null | grep -q .
then
    rm -rf "$BASE_DIR"/tmp/obfuscated_* "$BASE_DIR"/tmp/build_source_tigress_*
    find "$BASE_DIR/tmp" -maxdepth 1 -name 'source_tigress_*' ! -name 'source_tigress_source_cache' -exec rm -rf {} +
    echo "tmp/obfuscated_*, tmp/build_source_tigress_*, tmp/source_tigress_* (step 4 obfuscated source trees, excluding the persistent cross-campaign source cache) cleared"
fi
