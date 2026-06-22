#!/bin/bash
# =============================================================================
# Script   : 01_sync_dependencies.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Sync dependencies by downloading or resetting git submodules
# Usage    : ./scripts/01_sync_dependencies.sh
# =============================================================================

set -e

source "$(dirname "$0")/config.sh"

git -C "$BASE_DIR" submodule init

for dir in "$MUSL_DIR" "$TEST_DIR"
do
    if [ -z "$(ls -A "$dir/")" ]
    then
        echo "Downloading $(basename "$dir")"
        git -C "$BASE_DIR" submodule update -- "$dir"
    else
        echo "Reset $(basename "$dir")"
        git -C "$dir" reset --hard
        git -C "$dir" clean -fdxq
    fi
done
