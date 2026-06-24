#!/usr/bin/env python3
# =============================================================================
# Script   : 31_hamming_distances.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Compute pairwise Hamming distances between variants
# Usage    : ./scripts/31_hamming_distances.py
# =============================================================================

import os
import subprocess
import numpy as np
from scipy.spatial.distance import hamming
from tools import VARIANTS_DIR, RESULTS_DIR, get_variant_ids, save_stats, save_heatmap, save_matrix


def extract_text_section(so_path, variant_id):
    """Extract the .text section of a .so file as a byte array."""
    tmp = f"/tmp/text_{os.getpid()}_{variant_id}.bin"
    try:
        subprocess.run(
            ["objcopy", "--only-section=.text", so_path, tmp],
            check=True, capture_output=True
        )
        with open(tmp, "rb") as f:
            return np.frombuffer(f.read(), dtype=np.uint8)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def load_variants(variant_ids):
    """Load .text sections for all variants."""
    variants = []
    for variant_id in variant_ids:
        so_path = os.path.join(VARIANTS_DIR, variant_id, "lib", "libc.so")
        print(f"Loading {variant_id}...")
        text = extract_text_section(so_path, variant_id)
        variants.append((variant_id, text))
    return variants


def compute_hamming_distance_matrix(variants):
    """Compute the pairwise Hamming distance matrix between all variants."""
    n = len(variants)
    matrix = np.zeros((n, n))

    for i in range(n):
        for j in range(i + 1, n):
            a = variants[i][1]
            b = variants[j][1]
            min_len = min(len(a), len(b))
            dist = hamming(a[:min_len], b[:min_len])
            matrix[i][j] = dist
            matrix[j][i] = dist
        print(f"Progress: {i+1}/{n}")

    return matrix


if __name__ == "__main__":
    print("=== Loading variants ===")
    variant_ids = get_variant_ids()
    variants = load_variants(variant_ids)
    print(f"Loaded {len(variants)} variants")

    print("\n=== Computing Hamming distance matrix ===")
    matrix = compute_hamming_distance_matrix(variants)

    print("\n=== Saving results ===")
    save_stats(matrix, variant_ids, os.path.join(RESULTS_DIR, "hamming_stats.txt"))
    save_matrix(matrix, variant_ids, os.path.join(RESULTS_DIR, "hamming_matrix.csv"))
    save_heatmap(matrix, "Pairwaise Hamming distances between variants",
                 "Hamming distance", os.path.join(RESULTS_DIR, "hamming_heatmap.png"))

    print("\n=== Done ===")
