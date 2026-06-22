#!/bin/bash

set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS_DIR="$BASE_DIR/deps"
MUSL_DIR="$DEPS_DIR/musl"
TEST_DIR="$DEPS_DIR/libc-test"

TOOLCHAIN_DIR="$BASE_DIR/toolchain"
TOOLCHAIN_CC="$TOOLCHAIN_DIR/bin/musl-gcc"
TOOLCHAIN_LIB_DIR="$TOOLCHAIN_DIR/lib"
TOOLCHAIN_LINKER="$TOOLCHAIN_LIB_DIR/ld-musl-x86_64.so.1"

VARIANTS_DIR="$BASE_DIR/variants"
RESULTS_DIR="$BASE_DIR/results"
