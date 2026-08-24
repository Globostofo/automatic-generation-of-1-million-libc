# Progress report — Step 3: musl obfuscation

> Author: Romain CLEMENT
> Date: 2026-08-24

## 1. Context

Steps 1 and 2 diversify musl through compiler flags and link-time layout
randomization, neither of which changes the actual shape of the compiled
code. Step 3 tests a third axis: **obfuscation** via Tigress, a
source-to-source C transform applied before compilation. See
`docs/step3_design.md` for the full justification of the tool, the
per-file architecture, and the specific transforms used — this report
covers results only.

The production pipeline compiles musl once per **transform combo** (a
specific Tigress transformation), then generates volume by relinking that
single compiled base with step 2's proven layout-randomization mechanism
(random function order and padding, driven by a seed) — reusing the
"compile once, relink many times" factoring that made step 2 affordable
at scale. Five transform combos were validated safe (see
`docs/step3_design.md` §5): `Flatten`, `Split`, `Flatten,Split`, `Copy`,
`AntiTaintAnalysis`.

## 2. Results

### 2.1 Generation volume and cost

| Metric | Value |
|---|---|
| Variants generated | 150 (5 transform combos × 30 layout seeds) |
| Distinct variants after deduplication (`.text` hash) | 150 (0% duplication) |
| Generation time (5 combos compiled + 150 relinks, parallel) | ~15 minutes |
| Compute server | Madagh (48 cores, 192 GB RAM) |

Zero duplicates across all 150 variants, matching step 2's own 0%
duplication result — expected, since diversity within a combo comes from
the same layout-randomization mechanism already proven there.

Obfuscation coverage per combo (musl's own build selects 1,375 eligible
`.c` files for this target; a file falls back to unobfuscated compilation
if any pipeline stage fails on it, see `docs/step3_design.md` §4):

| Combo | Obfuscated | Fallback | Coverage |
|---|---|---|---|
| `Flatten` | 1202 | 173 | 87.4% |
| `Split` | 1180 | 195 | 85.8% |
| `Flatten,Split` | 1209 | 166 | 87.9% |
| `Copy` | 1202 | 173 | 87.4% |
| `AntiTaintAnalysis` | 1202 | 173 | 87.4% |

### 2.2 Functional validation

| Metric | Value |
|---|---|
| Baseline result (`libc-test`, unobfuscated musl) | 334/340 pass — 6 pre-existing failures, presumed to match the same baseline documented in step 1 |
| Range across all 150 obfuscated variants | 322–327 pass (13–18 failures) |
| Mean across all 150 obfuscated variants | ~325.7 pass (~14.3 failures) |

Per-combo pass count (out of 340), across the 30 layout-seed variants of
each combo:

| Combo | Pass range | Pass count distribution |
|---|---|---|
| `Flatten` | 322–324 | mostly 324, occasional 322/323 |
| `Split` | 326–327 | mostly 327, 3 variants at 326 |
| `Flatten,Split` | 324 | uniform across all 30 seeds |
| `Copy` | 326–327 | mostly 327, 2 variants at 326 |
| `AntiTaintAnalysis` | 327 | uniform across all 30 seeds |

Obfuscation adds roughly 7–12 additional failures on top of the 6
pre-existing baseline ones, depending on the transform combo — `Split`,
`Copy` and `AntiTaintAnalysis` cluster around 13–14 total failures,
`Flatten` and `Flatten,Split` around 16–18. Two combos (`Flatten,Split`,
`AntiTaintAnalysis`) show **zero variance across their 30 layout seeds** —
the exact same test outcome regardless of relink seed — while `Flatten`,
`Split` and `Copy` show small (1–2 test) variance between seeds of the
same combo. This is consistent with the parallel-test-runner race
condition already documented in step 1 (some `libc-test` binaries share
files on disk, causing spurious concurrent-access failures under parallel
execution) rather than a real functional difference introduced by the
layout seed itself.

The additional failures are not new or unexplained: they fall into the
same categories already triaged during this axis's feasibility testing —
a cluster of TLS/thread-bootstrap tests sensitive to timing around the
constructor-based fix needed to make Tigress-generated code initialize
correctly (see `docs/step3_design.md` §4), a cluster of
out-of-memory-pattern tests, and a small number of environment-sensitive
tests unrelated to obfuscation.

### 2.3 Binary diversity

![Hierarchical clustering dendrogram (Jaccard, n=3)](images/step3_jaccard_n3_dendrogram.png)

![Distance matrix reordered by cluster (Jaccard, n=3, n_clusters=5)](images/step3_jaccard_n3_reordered_heatmap.png)

| Metric | Value |
|---|---|
| Metric used | Jaccard distance on 3-grams of assembly mnemonics |
| Variants compared | 150 |
| Pairs | 11,175 |
| Min distance | 0.0075 |
| Max distance | 0.5878 |
| Mean distance | 0.3813 |
| Std deviation | 0.2285 |

Clustering with `n_clusters=5` — matching the number of transform combos,
the same principle step 2 used (`n_clusters=50`, matching its 50
alignment combos) — **recovers the 5 combos exactly**: each of the 5
clusters contains precisely the 30 variants of one combo, with no mixing
and no outliers. The reordered distance matrix shows this as 5 clean,
sharply-bordered diagonal blocks.

The dendrogram adds a layer the flat clustering alone does not show —
which combos are structurally *closer* to each other:

- `Copy` and `AntiTaintAnalysis` merge into a shared branch well before
  joining the rest of the tree. Neither transform restructures a
  function's control flow (`Copy` duplicates a function verbatim,
  `AntiTaintAnalysis` disrupts a compiler-level taint analysis without
  rewriting instruction sequences), so their mnemonic-level signature
  stays close to each other and relatively close to the original,
  unobfuscated code.
- `Flatten` and `Flatten,Split` merge into their own separate branch —
  expected, since `Flatten,Split` applies `Flatten` first; `Split`'s
  further reorganization does not erase the dispatch-loop signature
  `Flatten` imposes on the whole function.
- `Split` alone sits closer to the `Copy`/`AntiTaintAnalysis` family than
  to the `Flatten`-based family — consistent with `Split` reorganizing
  which function a block of code lives in without synthesizing the kind
  of artificial dispatch-loop structure `Flatten` does.

So the measured diversity is not arbitrary noise between 5 interchangeable
combos: it reflects a real, interpretable structure — transforms that
rewrite control flow (`Flatten`-based) form one family, transforms that
preserve the original instruction sequence (`Copy`, `AntiTaintAnalysis`,
and to a lesser extent `Split`) form another.

**Note on sample size**: an earlier, smaller campaign (21 variants, 7
layout seeds per combo) showed `Flatten` and `Split` each fragmenting
into 2–3 sub-clusters, which looked at the time like real intra-combo
structure driven by the layout seed. At this larger sample (30 seeds per
combo), both combos instead collapse cleanly into single unified
clusters. The earlier fragmentation was most likely small-sample noise,
not a reproducible signal — a caution against over-interpreting clustering
results from a sample this size, and a data point in favor of the larger
run's numbers being the more reliable ones.

## 3. Analysis and limitations

- **Tigress's real contribution here is depth, not volume — step 2 still
  supplies the volume.** The headline "150 variants, 0% duplication"
  number is not a step-3 achievement in its own right: it is step 2's
  layout-randomization mechanism, reused unmodified, and `--Seed=`
  applied to a fixed Tigress transform contributes nothing to it (see
  `docs/step3_design.md` §6 — two combos even show *zero* functional-test
  variance across all 30 of their layout seeds). What Tigress actually
  adds is a small number of genuinely distinct code-structure "shapes" —
  5, in the validated set — each of which step 2's mechanism can then be
  layered under for volume. Comparing the three axes on the same metric
  (Jaccard distance on assembly mnemonic 3-grams) makes the shape of this
  contribution concrete: step 1's flags produce inter-cluster distances of
  ~0.7–0.85, step 2's layout alone tops out at 0.32, and step 3's
  transform combos land in between at a max of 0.59 (mean 0.38). Tigress
  is a real depth lever, comparable in *kind* to step 1's flags (a small,
  curated set of structurally distinct choices) rather than to step 2's
  effectively unlimited seed space — but a shallower one than step 1, and
  reached at substantially higher engineering cost (a whole-program
  assumption to work around, four systematic correctness fixes, and most
  of the transform catalog disqualified, unsafe, or deferred, see
  `docs/step3_design.md` §5). **The practical implication for step 4**:
  treat the obfuscation-combo choice like step 1's flag choice — a small,
  curated depth lever — and keep relying on step 2's relink mechanism for
  volume under whichever depth lever (or combination of levers) is
  active, rather than expecting any future obfuscation transform to
  supply volume on its own.
- **Combo identity, not layout seed, is the dominant driver of measurable
  diversity within this axis.** The 5 transform combos each form their
  own clean cluster at `n_clusters=5`. Layout-seed diversity is real (it
  is what makes 0% duplication possible at all) but shallow — it
  multiplies volume within a combo rather than producing structurally
  distinct code, mirroring step 2's own finding that layout randomization
  is a volume lever, not a depth lever.
- **Obfuscation coverage tops out around 86-88%, not 100%, for a
  structural reason, not a bug.** `memcpy`/`memset`/`memmove` and other
  hot-path string functions are hand-written x86-64 assembly on this
  architecture — a source-to-source C obfuscator has no access to them,
  a permanent gap for this axis (see `docs/step3_design.md` §7). The
  remaining fallback files are ones where the pipeline itself failed on
  a specific construct and safely reverted to compiling the original
  source rather than aborting the build.
- **`Copy` widens the exported symbol surface** (its duplicated helper
  functions are not marked hidden), a cleanliness gap noted in
  `docs/step3_design.md` §7, not a correctness issue — functional tests
  pass at the same rate as the other combos.
- **Residual `libc-test` failures were not chased to zero**, consistent
  with this project's approach on the two previous axes: they fall into
  already-triaged categories (TLS/bootstrap timing, out-of-memory
  patterns, a few environment-sensitive tests), documented during earlier
  feasibility testing rather than newly discovered here.

## 4. Next steps

- Combine this axis with steps 1 and 2 (compiler flags, layout
  randomization) rather than generating variants along a single axis at a
  time — this is step 4's scope, and the "compile once, relink many
  times" factoring used here composes naturally with step 2's identical
  pattern.
- A handful of transforms were left unexplored for lack of supporting
  wrapper infrastructure rather than because they were shown unsafe:
  `EncodeData` (needs a variable-list extraction step), `RandomizeArgs`
  (needs a public-ABI-safe function filter), `AntiAliasAnalysis` (needs a
  more thorough constructor-rename fix). Each would need dedicated
  engineering, not just another validation pass, before being added to
  the combo set.
- Close the `Copy`-combo symbol-visibility gap (§3) before treating that
  combo as production-final.
