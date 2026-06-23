#!/bin/bash
# =============================================================================
# Script   : 01_sync_dependencies.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Sync dependencies by downloading or resetting git submodules
# Usage    : ./scripts/01_sync_dependencies.sh [musl|libc-test] ...
#            If no argument is given, all submodules are synced
# =============================================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPTS_DIR/config.sh"

declare -A SUBMODULES
SUBMODULES["musl"]="$MUSL_DIR"
SUBMODULES["libc-test"]="$TEST_DIR"

if [ "$#" -eq 0 ]
then
    TARGETS=("musl" "libc-test")
else
    TARGETS=()
    for arg in "$@"
    do
        if [ -n "${SUBMODULES[$arg]}" ]
        then
            TARGETS+=("$arg")
        else
            echo "Unknown submodule : $arg"
            echo "Usage: $0 [musl|libc-test] ..."
            exit 1
        fi
    done
fi

git -C "$BASE_DIR" submodule init

for name in "${TARGETS[@]}"
do
    dir="${SUBMODULES[$name]}"
    if [ -z "$(ls -A "$dir/")" ]
    then
        echo "Downloading $name..."
        git -C "$BASE_DIR" submodule update -- "$dir"
    else
        echo "Reset $name..."
        git -C "$dir" reset --hard
        git -C "$dir" clean -fdxq
    fi
done
