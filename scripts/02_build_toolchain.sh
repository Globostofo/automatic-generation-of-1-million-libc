#!/bin/bash
# =============================================================================
# Script   : 02_build_toolchain.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Build the reference toolchain from scratch using musl libc
# Usage    : ./scripts/02_build_toolchain.sh
# =============================================================================

set -e

source "$(dirname "$0")/config.sh"

if [ -z "$(ls -A "$TOOLCHAIN_DIR" | grep -v '^\.gitkeep$')" ]
then
    echo "Toolchain directory already empty"
else
    rm -r "$TOOLCHAIN_DIR/"*
    echo "Toolchain directory emptied"
fi

(
    cd "$MUSL_DIR"

    echo "Cleaning musl..."
    make clean > /dev/null 2>&1

    echo "Configuring..."
    ./configure \
        --prefix="$TOOLCHAIN_DIR" \
        --syslibdir="$TOOLCHAIN_LIB_DIR" \
        > /dev/null 2>&1

    echo "Compiling..."
    make -j$(nproc) > /dev/null 2>&1

    echo "Installing..."
    make install > /dev/null 2>&1
)

echo "Toolchain successfully compiled"
