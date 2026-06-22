#!/bin/bash
# =============================================================================
# Script   : 06_test_variant.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Run libc-test unit tests against a given musl variant
# Usage    : ./scripts/06_test_variant.sh <variant_id>
# =============================================================================

set -e

source "$(dirname "$0")/config.sh"

if [ "$#" -lt 1 ]
then
    echo "Usage: $0 <variant_id>"
    exit 1
fi

VARIANT_ID="$1"
VARIANT_DIR="$VARIANTS_DIR/$VARIANT_ID"
VARIANT_LIB_DIR="$VARIANT_DIR/lib"
LIBC_SO="$VARIANT_LIB_DIR/libc.so"
LINKER="$VARIANT_LIB_DIR/ld-musl-x86_64.so.1"
LOG="$RESULTS_DIR/${VARIANT_ID}.test.log"
RESULTS_FILE="$RESULTS_DIR/${VARIANT_ID}.test.txt"

log() { echo "$@" | tee -a "$LOG"; }

> "$LOG"
log "=== Tests variant ${VARIANT_ID} ==="
log ""
log "--- 1 : ELF File ---"

if [ ! -f "$LIBC_SO" ]
then
    log "[ERROR] libc.so is missing : $LIBC_SO"
    exit 1
fi

FILE_TYPE=$(file "$LIBC_SO")
if echo "$FILE_TYPE" | grep -q "ELF.*shared object"
then
    log "[PASS] ELF shared object is valid"
else
    log "[FAIL] Unexpected file type : $FILE_TYPE"
fi

if [ ! -f "$LINKER" ]
then
    log "[FAIL] Linker is missing : $LINKER"
else
    log "[PASS] Linker found : $LINKER"
fi

log ""
log "--- 2 : ABI symbols ---"

REQUIRED_SYMBOLS=(
    malloc free calloc realloc
    printf fprintf sprintf snprintf
    strlen strcpy strncpy strcmp strncmp strchr strstr memcpy memset memmove
    fopen fclose fread fwrite fseek ftell
    open close read write
    pthread_create pthread_join pthread_mutex_lock pthread_mutex_unlock
    exit abort getenv setenv
)
EXPORTED=$(nm -D "$LIBC_SO" 2> /dev/null | awk '$2 ~ /[TWi]/ {print $3}')
MISSING=()

for sym in "${REQUIRED_SYMBOLS[@]}"
do
    echo "$EXPORTED" | grep -qx "$sym" || MISSING+=("$sym")
done

EXPORTED_COUNT=$(echo "$EXPORTED" | wc -l)
log "[INFO] $EXPORTED_COUNT exported symbols"

if [ ${#MISSING[@]} -eq 0 ]
then
    log "[PASS] All the required symbols have been found (${#REQUIRED_SYMBOLS[@]}/${#REQUIRED_SYMBOLS[@]})"
else
    log "[FAIL] Missing symbols (${#MISSING[@]}) : ${MISSING[*]}"
fi

log ""
log "--- 3 : Functional tests ---"

PASS=0
FAIL=0
> "$RESULTS_FILE"

for exe in $(find "$TEST_DIR/src" -name "*.exe" ! -name "*-static.exe" ! -name "runtest.exe" | sort)
do
    if file "$exe" | grep -q "dynamically linked"
    then
        if { ( ulimit -c 0; $LINKER --library-path "$VARIANT_LIB_DIR" "$exe" ) > /dev/null 2>&1; } 2> /dev/null
        then
            PASS=$((PASS+1))
        else
            echo "FAIL $exe" >> "$RESULTS_FILE"
            FAIL=$((FAIL+1))
        fi
    fi
done

log "TOTAL $((PASS+FAIL))"
log "PASS  $PASS"
log "FAIL  $FAIL"
log "Details in $(basename "$(dirname "$RESULTS_FILE")")/$(basename "$RESULTS_FILE")"
