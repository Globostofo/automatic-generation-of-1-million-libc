#!/bin/bash
# =============================================================================
# Script   : 21_test_campaign_linear.sh
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Run tests on all musl variants
# Usage    : ./scripts/21_test_campaign_linear.sh
# =============================================================================

set -e

SCRIPTS_DIR="$(dirname "$0")"
source "$SCRIPTS_DIR/config.sh"

echo "=== Starting test campaign ==="

for variant in "$VARIANTS_DIR"/*
do
    "$SCRIPTS_DIR/20_test_variant.sh" $(basename "$variant")
done

echo "=== Done ==="
