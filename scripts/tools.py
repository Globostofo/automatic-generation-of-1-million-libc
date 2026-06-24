# =============================================================================
# Module   : tools.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Shared utilities for distance computation scripts
# =============================================================================

import os
import subprocess
import numpy as np
import matplotlib.pyplot as plt

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VARIANTS_DIR = os.path.join(BASE_DIR, "variants")
RESULTS_DIR = os.path.join(BASE_DIR, "results")


def get_variant_ids():
    """Return sorted list of variant IDs present in variants directory."""
    return sorted(
        v for v in os.listdir(VARIANTS_DIR)
        if v.isdigit() and os.path.exists(
            os.path.join(VARIANTS_DIR, v, "lib", "libc.so")
        )
    )


def extract_mnemonics(so_path):
    """Extract assembly mnemonics from a .so file using objdump."""
    result = subprocess.run(
        ["objdump", "-d", so_path],
        capture_output=True, text=True
    )
    mnemonics = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            mnemonic = parts[2].strip().split()[0]
            mnemonics.append(mnemonic)
    return mnemonics


def save_stats(matrix, variant_ids, path, extra={}):
    """Save distance matrix statistics to a text file."""
    upper = matrix[np.triu_indices(len(matrix), k=1)]
    with open(path, "w") as f:
        f.write(f"variants   : {len(variant_ids)}\n")
        for k, v in extra.items():
            f.write(f"{k:<11}: {v}\n")
        f.write(f"pairs      : {len(upper)}\n")
        f.write(f"min        : {upper.min():.6f}\n")
        f.write(f"max        : {upper.max():.6f}\n")
        f.write(f"mean       : {upper.mean():.6f}\n")
        f.write(f"std        : {upper.std():.6f}\n")
    print(f"Stats saved to {path}")


def save_heatmap(matrix, title, label, path):
    """Save the distance matrix as a heatmap image."""
    fig, ax = plt.subplots(figsize=(12, 10))
    im = ax.imshow(matrix, cmap="viridis", aspect="auto")
    plt.colorbar(im, ax=ax, label=label)
    ax.set_title(title)
    ax.set_xlabel("Variant")
    ax.set_ylabel("Variant")
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    print(f"Heatmap saved to {path}")


def save_matrix(matrix, variant_ids, path):
    """Save the raw distance matrix as a CSV file."""
    np.savetxt(path, matrix, delimiter=",", header=",".join(variant_ids))
    print(f"Matrix saved to {path}")
