#!/usr/bin/env python3
# =============================================================================
# Script   : analyze_step4_clusters.py
# Purpose  : One-off analysis helper (not part of the numbered pipeline).
#            Cross-references 34_clustering.py's cluster assignments against
#            step 4's own manifests (variant_id -> combo_id -> cflags) to
#            check whether cluster membership correlates with any single
#            flags axis (optimization level, inlining, unrolling, frame
#            pointer, march/mtune) -- answers "what is actually driving the
#            n_clusters split" instead of eyeballing variant ID ranges.
# Usage    : ./scripts/analyze_step4_clusters.py <clusters.txt> <combos_manifest.txt> <variant_manifest.txt>
#            Example: ./scripts/analyze_step4_clusters.py \
#                results/jaccard_n3_clusters.txt \
#                results/step4_combos_manifest.txt \
#                results/step4_manifest.txt
# =============================================================================

import sys
from collections import defaultdict


def parse_clusters(path):
    """variant_id -> cluster_id"""
    assignment = {}
    cluster_id = None
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("Cluster "):
                cluster_id = line.split()[1]
            elif line.strip().isdigit() or (line.strip() and line.strip()[0].isdigit()):
                vid = line.strip()
                if cluster_id is not None:
                    assignment[vid] = cluster_id
    return assignment


def parse_combos_manifest(path):
    """combo_id -> cflags (full string)"""
    combo_cflags = {}
    with open(path) as f:
        next(f)  # header
        for line in f:
            parts = line.split()
            if len(parts) < 4:
                continue
            combo_id = parts[0]
            cflags = " ".join(parts[3:])
            combo_cflags[combo_id] = cflags
    return combo_cflags


def parse_variant_manifest(path):
    """variant_id -> combo_id"""
    variant_combo = {}
    with open(path) as f:
        next(f)  # header
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            variant_combo[parts[0]] = parts[1]
    return variant_combo


def extract_axis(cflags, prefix):
    for tok in cflags.split():
        if tok.startswith(prefix):
            return tok
    return "(none)"


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: ./scripts/analyze_step4_clusters.py <clusters.txt> <combos_manifest.txt> <variant_manifest.txt>")
        sys.exit(1)

    clusters_path, combos_path, variants_path = sys.argv[1:4]

    variant_cluster = parse_clusters(clusters_path)
    combo_cflags = parse_combos_manifest(combos_path)
    variant_combo = parse_variant_manifest(variants_path)

    print(f"Parsed {len(variant_cluster)} clustered variants, {len(combo_cflags)} combos, {len(variant_combo)} variant->combo mappings")

    axes = {
        "optimization level": lambda c: next((t for t in c.split() if t.startswith("-O")), "(none)"),
        "inlining": lambda c: next((t for t in c.split() if "inline" in t), "(none)"),
        "unrolling": lambda c: next((t for t in c.split() if "unroll" in t), "(none)"),
        "frame pointer": lambda c: next((t for t in c.split() if "frame-pointer" in t), "(none)"),
        "march/mtune": lambda c: next((t for t in c.split() if t.startswith("-march") or t.startswith("-mtune")), "(none)"),
    }

    for axis_name, extractor in axes.items():
        print(f"\n=== Cross-tab: cluster x {axis_name} ===")
        table = defaultdict(lambda: defaultdict(int))
        clusters_seen = set()
        values_seen = set()
        missing = 0
        for vid, cid in variant_cluster.items():
            combo_id = variant_combo.get(vid)
            if combo_id is None:
                missing += 1
                continue
            cflags = combo_cflags.get(combo_id)
            if cflags is None:
                missing += 1
                continue
            value = extractor(cflags)
            table[cid][value] += 1
            clusters_seen.add(cid)
            values_seen.add(value)

        clusters_sorted = sorted(clusters_seen)
        values_sorted = sorted(values_seen)
        col_width = max((len(v) for v in values_sorted), default=0) + 2
        header = "cluster".ljust(10) + "".join(v.ljust(col_width) for v in values_sorted)
        print(header)
        for cid in clusters_sorted:
            row = cid.ljust(10) + "".join(str(table[cid].get(v, 0)).ljust(col_width) for v in values_sorted)
            print(row)
        if missing:
            print(f"  ({missing} variants skipped: no combo/cflags mapping found)")
