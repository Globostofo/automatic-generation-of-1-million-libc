#!/bin/bash

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -lt 1 ]
then
    echo "Usage: $0 <variant_id>"
    exit 1
fi

VARIANT_ID="$1"
PREFIX="$BASE_DIR/variants/${VARIANT_ID}"
LIB_PATH="$PREFIX/lib"
LIBC_SO="$LIB_PATH/libc.so"
LINKER="$LIB_PATH/ld-musl-x86_64.so.1"
LOG="$BASE_DIR/results/${VARIANT_ID}.test.log"
LIBC_TEST_DIR="$BASE_DIR/deps/libc-test"

log() { echo "$@" | tee -a "$LOG"; }

> "$LOG"
log "=== Tests variant ${VARIANT_ID} - $(date -Iseconds) ==="
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
    if echo "$EXPORTED" | grep -qx "$sym"
    then
        :
    else
        MISSING+=("$sym")
    fi
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

TEST_COUNT=0
FAILED=()
for exe in $(find "$LIBC_TEST_DIR/src" -name "*.exe" ! -name "*-static.exe" ! -name "runtest.exe")
do
    if file "$exe" | grep -q "dynamically linked"
    then
        TEST_COUNT=$((TEST_COUNT + 1))
        if ! $LINKER --library-path $LIB_PATH "$exe" > /dev/null 2>&1
        then
            FAILED+=($(basename "$exe"))
        fi
    else
        echo "SKIPPED $exe"
    fi
done

if [ ${#FAILED[@]} -eq 0 ]
then
    log "[PASS] Passed all the tests from libc-test ($TEST_COUNT/$TEST_COUNT)"
else
    log "[FAIL] Failed tests (${#FAILED[@]}) : ${FAILED[*]}"
fi
