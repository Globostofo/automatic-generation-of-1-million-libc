# Automatic Generation of 1 Million libc

Generating and analyzing libc binary variants at scale, to explore how far
software diversity can be pushed by combining several generation axes
(compiler flags, alternative libc implementations, obfuscation...).

## Step 1: musl + compiler flags

The repo currently implements a single generation axis: **musl libc built
with a grid of GCC compilation flags**. The pipeline covers:

1. building a reference musl toolchain and validating it against
   `libc-test` (baseline) ;
2. generating a large number of `libc.so` variants by combining flags
   (`-O*`, inlining, loop unrolling, frame pointer, march/mtune) ;
3. testing each variant against `libc-test` ;
4. deduplicating strictly identical variants (hash of the `.text`
   section) ;
5. measuring binary distances between variants and grouping them via
   hierarchical clustering.

Results so far: 720 variants generated, 248 distinct after
deduplication (many flag combinations produce the exact same binary).

## Requirements

- `git`, `gcc`, `make`, `binutils` (`objdump`, `objcopy`, `nm`, `file`)
- Python 3 with `numpy`, `scipy`, `matplotlib`

## Dependencies (submodules)

- `deps/musl` — musl libc sources
- `deps/libc-test` — functional test suite used to validate each variant

## Scripts

Scripts are grouped strictly by the tens digit of their filename.

### 0x — Setup

Sync dependencies, build a reference musl toolchain (no special flags) and
check it passes `libc-test`. Serves as the comparison baseline for variants.

| Script | Role | Usage |
|---|---|---|
| `config.sh` | Shared variables (paths to deps, toolchain, variants, results). Meant to be sourced, never run directly. | — |
| `01_sync_dependencies.sh` | Initializes/resets the `musl` and `libc-test` submodules (clone if missing, `reset --hard` + `clean -fdx` otherwise). | `./scripts/01_sync_dependencies.sh [musl\|libc-test] ...` (no argument: both) |
| `02_build_toolchain.sh` | Compiles and installs musl into `toolchain/` with default flags. | `./scripts/02_build_toolchain.sh` |
| `03_build_tests.sh` | Compiles the `libc-test` binaries against the reference toolchain. | `./scripts/03_build_tests.sh [--clean]` |
| `04_test_toolchain.sh` | Runs `libc-test` against the reference toolchain, writes failures to `results/toolchain.test.txt`. | `./scripts/04_test_toolchain.sh` |

### 1x — Variant generation

| Script | Role | Usage |
|---|---|---|
| `10_build_variant.sh` | Compiles a single `libc.so` variant with the given `CFLAGS`, installs it under `variants/<id>/`, computes size + SHA256 (full binary and `.text` section) into `results/<id>.meta.txt`. | `./scripts/10_build_variant.sh <variant_id> <cflags>` |
| `11_build_campaign_grid.sh` | Generates a combinatorial grid of flags (optimization level × inlining × unrolling × frame pointer × march/mtune) and builds all variants in parallel via `10_build_variant.sh`. | `./scripts/11_build_campaign_grid.sh [parallel_jobs]` |

### 2x — Variant testing

| Script | Role | Usage |
|---|---|---|
| `20_test_variant.sh` | Validates a variant: ELF format, presence of the linker, required ABI symbols, then a full `libc-test` run. Writes failing tests to `results/<id>.test.txt`. | `./scripts/20_test_variant.sh <variant_id>` |
| `21_test_campaign_linear.sh` | Runs `20_test_variant.sh` sequentially on all variants. | `./scripts/21_test_campaign_linear.sh` |
| `22_test_campaign_parallel.sh` | Same, in parallel. | `./scripts/22_test_campaign_parallel.sh [parallel_jobs]` |

### 3x — Post-processing

Deduplicate, then compare remaining variants against each other to measure
actual binary diversity.

| Script | Role | Usage |
|---|---|---|
| `30_deduplicate_variants.sh` | Compares the SHA256 hash of the `.text` section across variants, removes strict duplicates (keeps the first occurrence), writes a report to `results/deduplication.txt`. | `./scripts/30_deduplicate_variants.sh` |
| `31_hamming_distances.py` | Byte-wise Hamming distance between binaries. | `./scripts/31_hamming_distances.py` |
| `32_jaccard_distances.py` | Jaccard distance over n-grams of assembly mnemonics (`objdump`). | `./scripts/32_jaccard_distances.py [n]` (n = n-gram size, default 3) |
| `33_levenshtein_distances.py` | Levenshtein distance over mnemonic sequences. **Not used in practice**: already too costly at a few hundred variants (per-pair quadratic complexity). | `./scripts/33_levenshtein_distances.py` |
| `34_clustering.py` | Hierarchical clustering from a distance matrix (output of 31/32/33): dendrogram, reordered heatmap, cluster assignments. | `./scripts/34_clustering.py <matrix.csv> [n_clusters]` |
| `tools.py` | Shared utilities for 31/32/33/34 (variant listing, mnemonic extraction, matrix/heatmap/stats saving). Module, not executable. | — |

### 9x — Cleanup

| Script | Role | Usage |
|---|---|---|
| `99_clean_variants.sh` | Removes `variants/` and `results/` (with confirmation). Preserves the toolchain and compiled test binaries. | `./scripts/99_clean_variants.sh` |

## Directory layout

```
deps/          musl and libc-test submodules
toolchain/     reference musl toolchain (baseline)
variants/      generated libc.so files, one per variant_id
results/       logs, metadata, test results, distance matrices, plots
scripts/       pipeline described above
```

## Typical pipeline

```bash
./scripts/01_sync_dependencies.sh
./scripts/02_build_toolchain.sh
./scripts/03_build_tests.sh
./scripts/04_test_toolchain.sh          # baseline

./scripts/11_build_campaign_grid.sh     # generate variants
./scripts/22_test_campaign_parallel.sh  # test variants
./scripts/30_deduplicate_variants.sh    # remove strict duplicates

./scripts/32_jaccard_distances.py 3
./scripts/34_clustering.py results/jaccard_matrix.csv
```
