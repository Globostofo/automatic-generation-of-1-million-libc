#!/bin/bash
# =============================================================================
# Script   : 03_build_tests.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build libc-test unit tests against the reference toolchain
# Usage    : ./scripts/03_build_tests.sh [--clean]
# =============================================================================

set -e

CLEAN=false

while [[ $# -gt 0 ]]
do
    case "$1" in
        --clean)
            CLEAN=true
            ;;
        *)
            echo "Invalid option : $1"
            echo "Usage: $0 [--clean]"
            exit 1
            ;;
    esac
    shift
done

source "$(dirname "$0")/config.sh"

if [ ! -f "$TOOLCHAIN_CC" ]
then
    echo "Compiler not found : $TOOLCHAIN_CC"
    exit 1
fi

(
    cd "$TEST_DIR"
    if $CLEAN
    then
        echo "Cleaning..."
        make cleanall > /dev/null 2>&1
    fi
    echo "Compiling..."
    make -j$(nproc) CC="$TOOLCHAIN_CC" > /dev/null 2>&1
)

echo "Tests successfully compiled"
