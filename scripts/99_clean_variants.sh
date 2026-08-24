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
echo "         The toolchain, test binaries, and step1_distinct_flags.txt"
echo "         (step 4's deduplicated flags manifest) will be preserved."
echo ""
read -p "Are you sure? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]
then
    echo "Aborted."
    exit 0
fi

for dir in "$RESULTS_DIR" "$VARIANTS_DIR"
do
    if [ -z "$(ls -A "$dir" | grep -v '^\.' | grep -v 'toolchain.test.txt' | grep -v 'step1_distinct_flags.txt')" ]
    then
        echo "$(basename "$dir")/ already empty"
    else
        find "$dir" -mindepth 1 ! -name ".gitkeep" ! -name "toolchain.test.txt" ! -name "step1_distinct_flags.txt" -delete
        echo "$(basename "$dir")/ cleared"
    fi
done

if compgen -G "$BASE_DIR/tmp/base_*" > /dev/null
then
    rm -rf "$BASE_DIR"/tmp/base_*
    echo "tmp/base_* (step 2/4 base builds) cleared"
fi

if compgen -G "$BASE_DIR/tmp/obfuscated_*" > /dev/null || compgen -G "$BASE_DIR/tmp/build_source_tigress_*" > /dev/null || compgen -G "$BASE_DIR/tmp/source_tigress_*" > /dev/null
then
    rm -rf "$BASE_DIR"/tmp/obfuscated_* "$BASE_DIR"/tmp/build_source_tigress_* "$BASE_DIR"/tmp/source_tigress_*
    echo "tmp/obfuscated_*, tmp/build_source_tigress_*, tmp/source_tigress_* (step 4 obfuscated source trees) cleared"
fi
