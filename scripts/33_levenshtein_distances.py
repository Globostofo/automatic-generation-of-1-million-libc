#!/usr/bin/env python3
# =============================================================================
# Script   : 33_levenshtein_distances.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Compute pairwise Levenshtein distances between variants
# Usage    : ./scripts/33_levenshtein_distances.py
# =============================================================================

import os
import numpy as np
from tools import VARIANTS_DIR, RESULTS_DIR, get_variant_ids, extract_mnemonics, save_stats, save_heatmap, save_matrix


def load_variants(variant_ids):
    """Load all variants and extract their mnemonic sequences."""
    variants = []
    for variant_id in variant_ids:
        so_path = os.path.join(VARIANTS_DIR, variant_id, "lib", "libc.so")
        print(f"Loading {variant_id}...")
        mnemonics = extract_mnemonics(so_path)
        variants.append((variant_id, mnemonics))
    return variants


def levenshtein(a, b):
    """Compute normalized Levenshtein distance between two sequences."""
    la, lb = len(a), len(b)
    if la == 0 or lb == 0:
        return 1.0

    dp = list(range(lb + 1))
    for i in range(1, la + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, lb + 1):
            temp = dp[j]
            if a[i-1] == b[j-1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j-1])
            prev = temp

    return dp[lb] / max(la, lb)


def compute_distance_matrix(variants):
    """Compute the pairwise Levenshtein distance matrix between all variants."""
    n = len(variants)
    matrix = np.zeros((n, n))

    for i in range(n):
        for j in range(i + 1, n):
            dist = levenshtein(variants[i][1], variants[j][1])
            matrix[i][j] = dist
            matrix[j][i] = dist
        print(f"Progress: {i+1}/{n}")

    return matrix


if __name__ == "__main__":
    print("=== Loading variants ===")
    variant_ids = get_variant_ids()
    variants = load_variants(variant_ids)
    print(f"Loaded {len(variants)} variants")

    print("\n=== Computing Levenshtein distance matrix ===")
    matrix = compute_distance_matrix(variants)

    print("\n=== Saving results ===")
    save_stats(matrix, variant_ids, os.path.join(RESULTS_DIR, "levenshtein_stats.txt"))
    save_matrix(matrix, variant_ids, os.path.join(RESULTS_DIR, "levenshtein_matrix.csv"))
    save_heatmap(matrix, "Pairwise Levenshtein distances between musl variants",
                 "Levenshtein distance", os.path.join(RESULTS_ID, "levenshtein_heatmap.png"))

    print("\n=== Done ===")
