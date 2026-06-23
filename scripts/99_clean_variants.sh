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
