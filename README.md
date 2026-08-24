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

## Step 2: musl + layout randomization

Second generation axis, isolated from step 1's flags: **layout
randomization** of the same musl codebase, with the optimization level fixed
to `-O2`. Two random levers are drawn together per variant:

- alignment jitter (`-falign-functions/-loops/-jumps/-labels`, compile-time) ;
- function order and zero-filled padding gaps between functions (link-time,
  via a generated partial linker script), driven by a single random seed.

Generation is factored (compile once per alignment combo, cheap relink per
seed) to keep this affordable at scale. Results so far: 500 variants
generated (50 combos × 10 seeds), **0% duplication** (vs. 65% for step 1's
flags), 0 functional regressions. See `docs/step2_report.md` for the full
analysis, including why this axis supplies near-unlimited volume while
step 1's flags remain necessary for diversity depth.

## Step 3: musl + obfuscation

Third generation axis: **obfuscation** via [Tigress](https://tigress.wtf), a
source-to-source C transform applied before compilation, chosen over OLLVM to
stay on the existing GCC/musl toolchain. Each eligible `.c` file gets one of 5
validated transforms (`Flatten`, `Split`, `Flatten,Split`, `Copy`,
`AntiTaintAnalysis`), assigned independently and deterministically per file,
seeded per variant — this uses a real combinatorial space instead of a
handful of discrete transform choices, and was confirmed to produce a genuine
diversity *continuum* rather than clusters (N=25, mean pairwise Jaccard
distance 0.36, std 0.017). See `docs/step3_design.md` for the full
architecture (four systematic correctness fixes needed to make Tigress safe
on musl, why per-file beats whole-program merging) and `docs/step3_report.md`
for results.

## Step 4: axis combination (in progress)

Combines all three axes — flags (step 1), layout randomization (step 2), and
obfuscation (step 3) — into a single pipeline, instead of generating each in
isolation. Architecture: obfuscate the corpus once per Tigress assignment
seed (`17_build_source_tigress.sh`, expensive), compile that same obfuscated
source with each of a fixed number of randomly drawn flag combos
(`18_build_base_step4.sh`, cheap — Tigress only ever sees one reference
preprocess, so it doesn't need rerunning per flags combo), then relink with
step 2's layout mechanism (`13_build_variant_random.sh`, reused unchanged,
near-free). The flags axis draws `flags_combos` distinct tuples at random
from step 1's own 5 axes (optimization level, inlining, unrolling, frame
pointer, march/mtune), same fixed-N draw pattern steps 2 and 3 already use,
rather than crossing the full 720-combo grid or depending on step 1's own
scripts/results — step 1's report already showed ~65% of the full grid is
redundant on plain musl (see Step 1 above), and whether that duplication
pattern transfers to Tigress-obfuscated source is unverified, so this design
doesn't assume it: `30_deduplicate_variants.sh` measures the real
duplication rate on the actual obfuscated output instead. This keeps the
expensive axis (Tigress) repeated the fewest times while still combining all
three levers, each independently toggleable in `19_build_campaign_step4.sh`.
Not yet run at production scale — mechanism validated locally, no report
yet.

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
| `12_build_base_random.sh` | Compiles a "base" build of musl (`-O2` + a given alignment combo) and keeps it on disk under `tmp/base_<combo_id>/`, along with the list of `.text.*` sections found (`results/base_<combo_id>.sections.txt`). Compilation only depends on the alignment flags, so this is shared by every variant built from the same combo. | `./scripts/12_build_base_random.sh <combo_id> <align_functions> <align_loops> <align_jumps> <align_labels>` |
| `13_build_variant_random.sh` | Relinks a single variant from an already-built base (see above): generates a linker script placing `.text.*` sections in a random order with random padding gaps (driven by a seed), relinks (guarded by a per-combo `flock` since several variants may share the same base concurrently), installs under `variants/<id>/`. Same `results/<id>.meta.txt` output as `10_build_variant.sh`, plus the alignment/seed parameters. | `./scripts/13_build_variant_random.sh <variant_id> <combo_id> <seed> [pad_min] [pad_max]` |
| `14_build_campaign_random.sh` | Draws `K` distinct alignment combos and `seeds_per_combo` random seeds per combo, writes `results/random_combos_manifest.txt` and `results/random_manifest.txt`, then runs one job per combo in parallel — each job builds its base (`12_build_base_random.sh`) and relinks all its variants sequentially (`13_build_variant_random.sh`), so a combo that finishes compiling early starts relinking without waiting for the others. | `./scripts/14_build_campaign_random.sh [K] [seeds_per_combo] [parallel_jobs]` |
| `gen_order_script.py` | Helper used by `13_build_variant_random.sh`: given a list of `.text.*` section names (stdin) and a seed, prints a partial linker script (`SECTIONS { .text : {...} } INSERT AFTER .text;`) with the sections in a random order and random padding gaps between them. Module, not meant to be run standalone. | `readelf -S --wide *.lo \| grep -oP '\.text\.\S+' \| sort -u \| ./scripts/gen_order_script.py <seed> [pad_min] [pad_max]` |
| `15_build_variant_tigress_mixed.sh` | Step 3. Builds a single variant with a per-file random Tigress transform assignment (via `tigress_cc_wrapper.sh`'s `TIGRESS_ASSIGNMENT_SEED`) — every eligible `.c` file independently gets one of 5 validated transforms. No relink: each variant is its own full corpus compile, isolating obfuscation's own diversity contribution. | `./scripts/15_build_variant_tigress_mixed.sh <variant_id> <assignment_seed>` |
| `16_build_campaign_tigress_mixed.sh` | Step 3 campaign: builds `N` mixed-assignment variants in parallel, each with its own random assignment seed, sharing a Tigress output cache across the whole campaign (unique work converges toward ~5 full-corpus passes regardless of `N`). | `./scripts/16_build_campaign_tigress_mixed.sh [N] [parallel_jobs]` |
| `17_build_source_tigress.sh` | Step 4. Obfuscates the whole musl corpus once for a given Tigress assignment seed (per-file mixed transform assignment, see `tigress_cc_wrapper.sh`) and persists the result as a source tree under `tmp/obfuscated_<seed>/`, instead of compiling it — lets the obfuscation axis be crossed against step 1's flags without rerunning Tigress per flags combo. | `./scripts/17_build_source_tigress.sh <assignment_seed>` |
| `18_build_base_step4.sh` | Step 4. Overlays an obfuscated source tree (from `17_`) onto a fresh musl checkout and compiles it with a given step-1 `CFLAGS` combo (plain compiler, no Tigress involved here), producing `tmp/base_<combo_id>/` + `results/base_<combo_id>.sections.txt` in the same shape as `12_build_base_random.sh`, so `13_build_variant_random.sh` relinks it unchanged. | `./scripts/18_build_base_step4.sh <combo_id> <assignment_seed> <cflags>` |
| `19_build_campaign_step4.sh` | Step 4 campaign orchestrator: crosses `tigress_seeds` assignment seeds × `flags_combos` distinct flag tuples drawn at random from step 1's 5 axes (not the full 720-combo grid, not a dependency on step 1's own scripts/results) × `relink_seeds_per_base` layout seeds. Runs `17_` once per seed, then one job per (seed, flags combo) pair building its base (`18_`) and relinking all its variants (`13_build_variant_random.sh`, reused unchanged). | `./scripts/19_build_campaign_step4.sh [tigress_seeds] [flags_combos] [relink_seeds_per_base] [parallel_jobs]` |
| `tigress_cc_wrapper.sh` | `CC=` substitute used by steps 3-4's builds: obfuscates each `.c` file via Tigress before compiling (per-file transform assignment, systematic correctness fixes for musl's `[static N]` syntax, `weak_alias` visibility, and static-initializer/constructor timing — see `docs/step3_design.md`), falling back to the original source on any failure. Supports an output cache (keyed by file/transform/flags) and, for step 4, a source-tree dump mode (`TIGRESS_OUTPUT_SOURCE_DIR`) instead of compiling inline. Not meant to be run directly — set as `CC` during `./configure`. | — |

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
| `99_clean_variants.sh` | Removes `variants/`, `results/` and any leftover `tmp/base_*` base builds (with confirmation). Preserves the toolchain and compiled test binaries. | `./scripts/99_clean_variants.sh` |

## Directory layout

```
deps/          musl and libc-test submodules
toolchain/     reference musl toolchain (baseline)
variants/      generated libc.so files, one per variant_id
results/       logs, metadata, test results, distance matrices, plots
scripts/       pipeline described above
docs/          written reports and their images
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

Step 2 (layout randomization) reuses the same testing/dedup/distance scripts,
swapping the generation step for `14_build_campaign_random.sh` (which itself
drives `12_build_base_random.sh` and `13_build_variant_random.sh`). Since
those scripts scan the whole `variants/`/`results/` directories, run
`99_clean_variants.sh` first to avoid mixing axes:

```bash
./scripts/99_clean_variants.sh
./scripts/14_build_campaign_random.sh   # generate variants (layout randomization)
./scripts/22_test_campaign_parallel.sh
./scripts/30_deduplicate_variants.sh

./scripts/32_jaccard_distances.py 3
./scripts/34_clustering.py results/jaccard_n3_matrix.csv
```

Step 3 (obfuscation) similarly swaps the generation step for
`16_build_campaign_tigress_mixed.sh` (requires `TIGRESS_EXTRA_ARGS`, e.g.
`--Environment=x86_64:Linux:Gcc:4.6`); step 4 (axis combination) swaps it for
`19_build_campaign_step4.sh`, same requirement — no other prerequisite, it
draws its own random flag combos and doesn't depend on step 1's scripts or
results:

```bash
./scripts/99_clean_variants.sh
TIGRESS_EXTRA_ARGS="--Environment=x86_64:Linux:Gcc:4.6" \
    ./scripts/19_build_campaign_step4.sh   # generate variants (flags x layout x obfuscation)
./scripts/22_test_campaign_parallel.sh
./scripts/30_deduplicate_variants.sh

./scripts/32_jaccard_distances.py 3
./scripts/34_clustering.py results/jaccard_n3_matrix.csv
```
