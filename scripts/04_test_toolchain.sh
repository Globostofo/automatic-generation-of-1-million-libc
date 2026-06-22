#!/bin/bash
# =============================================================================
# Script   : 04_test_toolchain.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Run libc-test unit tests against the reference toolchain
# Usage    : ./scripts/04_test_toolchain.sh
# =============================================================================

set -e

source "$(dirname "$0")/config.sh"

RESULTS_FILE="$RESULTS_DIR/toolchain.test.txt"

if [ ! -f "$TOOLCHAIN_LINKER" ]
then
    echo "Linker not found : $TOOLCHAIN_LINKER"
    exit 1
fi

PASS=0
FAIL=0
> "$RESULTS_FILE"

echo "Running the tests..."
for exe in $(find "$TEST_DIR/src" -name "*.exe" ! -name "*-static.exe" ! -name "runtest.exe" | sort)
do
    if file "$exe" | grep -q "dynamically linked"
    then
        if { ( ulimit -c 0; $TOOLCHAIN_LINKER --library-path "$TOOLCHAIN_LIB_DIR" "$exe" ) > /dev/null 2>&1; } 2> /dev/null
        then
            PASS=$((PASS+1))
        else
            echo "FAIL $exe" >> "$RESULTS_FILE"
            FAIL=$((FAIL+1))
        fi
    fi
done

echo "TOTAL $((PASS+FAIL))"
echo "PASS  $PASS"
echo "FAIL  $FAIL"
echo "Details in $(basename "$(dirname "$RESULTS_FILE")")/$(basename "$RESULTS_FILE")"
