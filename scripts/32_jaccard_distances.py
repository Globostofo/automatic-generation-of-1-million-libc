#!/usr/bin/env python3
# =============================================================================
# Script   : 32_jaccard_distances.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Compute pairwise Jaccard distances between variants
# Usage    : ./scripts/32_jaccard_distances.py
# =============================================================================

import os
import numpy as np
from tools import VARIANTS_DIR, RESULTS_DIR, get_variant_ids, extract_mnemonics, save_stats, save_heatmap, save_matrix

N = 3


def build_ngrams(mnemonics, n):
    """Build a set of n-grams from a list of mnemonics."""
    return set(tuple(mnemonics[i:i+n]) for i in range(len(mnemonics) - n + 1))


def load_variants(variant_ids):
    """Load all variants and compute their n-gram sets."""
    variants = []
    for variant_id in variant_ids:
        so_path = os.path.join(VARIANTS_DIR, variant_id, "lib", "libc.so")
        print(f"Loading {variant_id}...")
        mnemonics = extract_mnemonics(so_path)
        ngrams = build_ngrams(mnemonics, N)
        variants.append((variant_id, ngrams))
    return variants


def jaccard(a, b):
    """Compute Jaccard distance between two sets."""
    intersection = len(a & b)
    union = len(a | b)
    if union == 0:
        return 0.0
    return 1.0 - intersection / union


def compute_distance_matrix(variants):
    """Compute the pairwise Jaccard distance matrix between all variants."""
    n = len(variants)
    matrix = np.zeros((n, n))

    for i in range(n):
        for j in range(i + 1, n):
            dist = jaccard(variants[i][1], variants[j][1])
            matrix[i][j] = dist
            matrix[j][i] = dist
        print(f"Progress: {i+1}/{n}")

    return matrix


if __name__ == "__main__":
    print(f"=== Loading variants (n-gram size: {N}) ===")
    variant_ids = get_variant_ids()
    variants = load_variants(variant_ids)
    print(f"Loaded {len(variants)} variants")

    print("\n=== Computing Jaccard distance matrix ===")
    matrix = compute_distance_matrix(variants)

    print("\n=== Saving results ===")
    save_stats(matrix, variant_ids, os.path.join(RESULTS_DIR, "jaccard_stats.txt"), extra={"n-gram": N})
    save_matrix(matrix, variant_ids, os.path.join(RESULTS_DIR, "jaccard_matrix.csv"))
    save_heatmap(matrix, f"Pairwise Jaccard distances between musl variants (n={N})",
                 "Jaccard distance", os.path.join(RESULTS_DIR, "jaccard_heatmap.png"))

    print("\n=== Done ===")
