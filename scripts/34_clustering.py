#!/usr/bin/env python3
# =============================================================================
# Script   : 34_clustering.py
# Author   : Romain CLEMENT <romain.clement2301@gmail.com>
# Date     : 2026
# Purpose  : Hierarchical clustering of variants from a distance matrix
# Usage    : ./scripts/34_clustering.py <matrix.csv>
# =============================================================================

import os
import sys
import numpy as np
import matplotlib.pyplot as plt
from scipy.cluster.hierarchy import dendrogram, linkage, fcluster
from scipy.spatial.distance import squareform
from tools import RESULTS_DIR, get_variant_ids


def load_matrix(path):
    """Load a distance matrix from a CSV file."""
    return np.loadtxt(path, delimiter=",", comments="#")


def cluster(matrix, variant_ids, method="average"):
    """Perform hierarchical clustering on a distance matrix."""
    condensed = squareform(matrix)
    Z = linkage(condensed, method=method)
    return Z


def save_dendrogram(Z, variant_ids, path):
    """Save the dendrogram as an image."""
    fig, ax = plt.subplots(figsize=(20, 8))
    dendrogram(Z, labels=variant_ids, ax=ax, leaf_rotation=90, leaf_font_size=6)
    ax.set_title("Hierarchical clustering of musl variants")
    ax.set_xlabel("Variant")
    ax.set_ylabel("Distance")
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    print(f"Dendrogram saved to {path}")


def save_reordered_heatmap(matrix, Z, variant_ids, n_clusters, path):
    """Save the distance matrix reordered by cluster with cluster boundaries."""
    from scipy.cluster.hierarchy import leaves_list, fcluster
    from matplotlib.patches import Rectangle

    order = leaves_list(Z)
    reordered = matrix[np.ix_(order, order)]
    reordered_ids = [variant_ids[i] for i in order]
    labels = fcluster(Z, n_clusters, criterion="maxclust")
    reordered_labels = [labels[i] for i in order]

    fig, ax = plt.subplots(figsize=(12, 10))
    im = ax.imshow(reordered, cmap="viridis", aspect="auto")
    plt.colorbar(im, ax=ax, label="Distance")

    boundaries = [0] + [i for i in range(1, len(reordered_labels))
                  if reordered_labels[i] != reordered_labels[i-1]] + [len(reordered_labels)]
    for idx, (start, end) in enumerate(zip(boundaries, boundaries[1:])):
        size = end - start
        rect = Rectangle((start - 0.5, start - 0.5), size, size,
                          fill=False, edgecolor="red", linewidth=2)
        ax.add_patch(rect)

    ax.set_title(f"Distance matrix reordered by cluster (n={n_clusters})")
    ax.set_xlabel("Variant")
    ax.set_ylabel("Variant")
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    print(f"Reordered heatmap saved to {path}")


def save_cluster_assignments(Z, variant_ids, n_clusters, path):
    """Save cluster assignments for each variant."""
    labels = fcluster(Z, n_clusters, criterion="maxclust")
    with open(path, "w") as f:
        f.write(f"n_clusters : {n_clusters}\n\n")
        for cluster_id in range(1, n_clusters + 1):
            members = [variant_ids[i] for i, l in enumerate(labels) if l == cluster_id]
            f.write(f"Cluster {cluster_id:02d} ({len(members)} variants):\n")
            for m in members:
                f.write(f"  {m}\n")
            f.write("\n")
    print(f"Cluster assignments saved to {path}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: ./scripts/34_clustering.py <matrix_csv>")
        sys.exit(1)

    matrix_path = sys.argv[1]
    n_clusters = int(sys.argv[2]) if len(sys.argv) > 2 else 6
    name = os.path.basename(matrix_path).replace("_matrix.csv", "")

    print(f"=== Loading matrix from {matrix_path} ===")
    matrix = load_matrix(matrix_path)
    variant_ids = get_variant_ids()
    print(f"Loaded {len(variant_ids)} variants")

    print("\n=== Clustering ===")
    Z = cluster(matrix, variant_ids)

    print("\n=== Saving results ===")
    save_dendrogram(Z, variant_ids, os.path.join(RESULTS_DIR, f"{name}_dendrogram.png"))
    save_reordered_heatmap(matrix, Z, variant_ids, n_clusters, os.path.join(RESULTS_DIR, f"{name}_reordered_heatmap.png"))
    save_cluster_assignments(Z, variant_ids, n_clusters, os.path.join(RESULTS_DIR, f"{name}_clusters.txt"))

    print("\n=== Done ===")
