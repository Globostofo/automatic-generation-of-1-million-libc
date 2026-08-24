# Design notes — Step 3: obfuscation

> Author: Romain CLEMENT
> Date: 2026-08-24

## 1. Context and goal

Steps 1 and 2 diversify musl through mechanisms that never touch the actual
instruction-level shape of a function: compiler flags (step 1) select
between a handful of pre-existing codegen strategies, and layout
randomization (step 2) only reorders and pads already-compiled code.
**Obfuscation** is the third diversification axis: a source-to-source
transform that actually rewrites the control flow and structure of the
code itself, prior to compilation.

This document justifies the design choices behind step 3's pipeline —
why this tool, why this architecture, why these specific transforms and
not others. Results (generation volume, functional validation, binary
diversity) are reported separately in `docs/step3_report.md`.

## 2. Tool choice: Tigress over OLLVM

Two source-to-source/compiler-level obfuscators were considered: **Tigress**
(a standalone C-to-C obfuscator) and **OLLVM** (a patched LLVM/Clang fork
with obfuscation passes). Tigress was chosen because it plugs directly into
the existing GCC/musl toolchain — a normal `gcc` compiles its output —
whereas OLLVM would require standing up and maintaining a separate
Clang+OLLVM toolchain alongside the GCC one already used by steps 1 and 2.
This mirrors the same reasoning that ruled out switching to LLVM during
step 2's scoping.

## 3. Architecture: per-file, not whole-program

Tigress is a **whole-program** obfuscator: it expects a single C file
representing the entire program, with exactly one `main()`. musl's own
build compiles roughly 1,300+ independent `.c` files into `lib/libc.so`,
each with no `main()` of its own — a structural mismatch that had to be
resolved before anything else.

Two architectures were evaluated:

- **Per-file**: treat each musl source file as its own tiny "program" by
  appending a stub `main()`, obfuscate it in isolation, then let the
  normal musl build link everything together as usual.
- **Whole-program merge**: concatenate the (relevant subset of) musl's
  source files into one large translation unit and obfuscate it in a
  single Tigress invocation, unlocking Tigress's own function-merging and
  cross-file transforms.

The whole-program path was seriously explored, because it would have
opened access to Tigress transforms that fundamentally require seeing
more than one function's callers to work correctly (see §5). It was
abandoned after merging surfaced an escalating sequence of four distinct
collision categories at increasing scope, each needing its own detection
mechanism, each discovered only after the previous one was fixed:

1. `static` function/variable symbol collisions (detectable via `nm` on
   separately-compiled objects).
2. Macro leakage between merged files — musl relies on per-file local
   `#define`s (e.g. `#define malloc __libc_malloc_impl`) with no matching
   `#undef`, an assumption that only holds under separate compilation.
3. `weak_alias(...)` target collisions and `struct`/`union`/`enum` tag
   collisions — harmless across separate translation units, hard
   redefinitions once merged.
4. Small `static const` scalars that get constant-folded away at `-O2`
   and never appear in a compiled object's symbol table at all — invisible
   to the detection method used for category 1, so re-attempting a
   full-corpus merge after fixing categories 1–3 actually *increased* the
   error count (177 → 564) instead of converging to zero.

At full corpus scale, object-level collision detection proved structurally
insufficient — full coverage would require source-level analysis across
the whole corpus, a disproportionate investment for a benefit (cross-file
transforms) that was never concretely needed once the per-file
architecture was made to work. **Per-file was kept as the production
architecture.** This decision does have a direct, documented cost: any
Tigress transform whose correctness depends on seeing a function's real
callers across files does not work safely in this architecture (see §5,
`Inline`).

## 4. Making Tigress work on real musl source: four systematic fixes

Even restricted to a single file, applying Tigress directly to musl source
does not work out of the box. Four fixes, applied uniformly by the build
wrapper to every file, were needed to get correct results:

1. **`[static N]` array-parameter syntax (C99)** — not supported by
   Tigress's parser. Sanitized to plain `[N]` on the preprocessed source
   before obfuscation; semantically inert per C99 §6.7.5.3 (always decays
   to the same pointer type), and confirmed to only affect internal-only
   musl functions.
2. **GCC-synthesized clone symbols** (e.g. `pad.part.0`, produced by GCC's
   own inlining/cloning passes) must be filtered out of the function list
   passed to Tigress, or it errors on a function it cannot find at the
   source level.
3. **Constructor-rename instead of stub-`main`-stripping.** Tigress
   requires a `main()`; the naive fix (compile the stub in, then strip the
   `main` symbol from the resulting object) is a critical, silent
   correctness bug: Tigress rewrites every statically-initialized
   global/static variable into individual runtime assignments placed
   *inside* its generated `main()`, rather than a normal C initializer. If
   `main()` never executes, every such global silently stays
   zero/NULL-initialized. The fix is to rename the generated `main()` into
   an `__attribute__((constructor))` function instead of stripping it, so
   it still runs automatically at load time.
4. **`weak_alias(...)` visibility.** musl declares most of its public ABI
   functions as `weak_alias(internal_name, public_name)`. Tigress
   correctly turns this into a real trampoline function, but marks it
   `hidden`-visibility instead of the default/exported visibility the
   `weak_alias` macro originally provided — silently dropping the public
   symbol from the shared library's dynamic symbol table, with no build
   error. Fixed by detecting `weak_alias` targets in the pre-obfuscation
   source and stripping the incorrectly-added `hidden` attribute from
   those specific names in Tigress's output.

Any file where the pipeline fails at any stage (compilation, Tigress
itself, or a post-processing step) falls back to compiling the original,
unobfuscated source rather than aborting the whole build — this is what
lets a full-corpus build complete unattended, at the cost of leaving a
minority of files unobfuscated (quantified in the report).

## 5. Transform selection

Tigress offers dozens of transforms, organized by tigress.wtf into
control-flow, data, function-level, integrity, anti-analysis, and
miscellaneous categories. Several categories were excluded outright before
any testing:

- **Integrity/anti-tamper** (`Checksum`, `SelfModify`, `CheckEnvironment`)
  — actively hostile to this project's own goals: steps 30–34's
  binary-distance and clustering tooling *is* static analysis on the
  generated variants, and these transforms exist specifically to detect
  or defeat that kind of inspection at runtime.
- **`Virtualize`/`Jit`/`JitDynamic`** — too heavy and too risky for a
  foundational libc: order-of-magnitude code size and slowdown in general
  obfuscation literature, plus the added complexity of executable memory
  at runtime.
- **`RandomFuns`** — generates decoy functions; does not transform real
  musl code, so it contributes nothing to this axis.

Every remaining candidate was tested empirically, at two levels: a
small representative sample first (8 files spanning `weak_alias`,
large static tables, `hidden`-visibility, and macro-heavy code), then a
full local corpus build for anything that passed. Five transforms were
validated safe and form the production combo set; the rest were rejected,
each for a distinct, concrete reason rather than by category:

| Transform | Status | Reason |
|---|---|---|
| `Flatten` | **Validated** | Control-flow flattening into a dispatch loop; no runtime support library needed. |
| `Split` | **Validated** | Splits a function into sub-parts; purely structural, no external call-graph visibility required. |
| `Flatten,Split` | **Validated** | Chained combination of the above two. |
| `Copy` | **Validated** | Duplicates a function; purely additive, cannot delete anything. |
| `AntiTaintAnalysis` | **Validated** | Disrupts a *compiler's* taint analysis; confirmed not to interfere with this project's own binary-diversity measurement, which operates on the compiled output, not on Tigress's internal analysis passes. |
| `EncodeArithmetic` / `InitOpaque` family (`AddOpaque`, `EncodeLiterals`) | Rejected | Needs `InitOpaque`'s runtime opaque-predicate support library, whose generated constructor runs *after* `ld.so`'s own internal bootstrap use of `malloc` (musl's `ld.so` *is* `libc.so`). A statically-initialized table needed that early (mallocng's size-class table) stays zero-initialized, causing an infinite-recursion stack-overflow crash; excluding the affected file only traded that crash for a separate `dlopen` deadlock (the constructor-running window is long enough, across ~1,200 files, to reliably hit a lock-contention race that is normally too narrow to trigger). A real fix would require reconstructing genuine static C initializers from Tigress's runtime-assignment output — scoped, not built. |
| `Inline` | **Disqualified** | Deletes function bodies outright, silently. `Inline` finds call sites of a target function and removes the now-presumed-dead original definition. In this project's per-file architecture, Tigress never sees a function's real callers (they live in other files, linked in later) — so every function looks unreferenced from its isolated point of view, and its body is deleted. Confirmed by disassembling the result: `strcmp.o` contained nothing but the constructor stub, `strcmp` itself was gone. Not a configuration issue — a hard architectural incompatibility that would require the whole-program merge already rejected in §3. |
| `EncodeData` | Not attempted | Requires an explicit `--GlobalVariables=`/`--LocalVariables=` list; the wrapper only auto-derives a function list (via `nm`), no equivalent variable-list extraction exists. Real engineering work, not a validation question. |
| `AntiAliasAnalysis` | Not attempted | Breaks the constructor-rename fix from §4: its generated analysis output embeds a bare reference to the identifier `main` *inside* the renamed function's body, which the rename script (regex-based, only rewrites the signature/declaration) does not catch, causing a compile error. Fixable in principle, deferred as too risky to patch blindly under time pressure. |
| `RandomizeArgs` | Not attempted | Changing a function's signature is safe only for internal (`static`/`hidden`) functions — applying it to a public ABI function would break musl's API. Requires a new function-list filter in the wrapper (real engineering, not yet built). |
| `Merge` | Not attempted | Suspected of the same cross-call-site visibility problem as `Inline` (Tigress's own documentation shows it normally operating across multiple merged files); also showed an unexplained `MISSING-MAIN` anomaly during early exploration. Not tested with full rigor. |

## 6. Diversity mechanism: per-file random transform assignment

This went through two prior designs before arriving at the current one,
each ruled out by a concrete finding rather than by preference.

**Design 1 — re-obfuscate per variant with a new `--Seed=`.** The first
working pipeline re-obfuscated musl from scratch for every variant, using
Tigress's own `--Seed=` option to vary the output. This was a false
premise: comparing the disassembly of the same file obfuscated twice with
`Flatten,Split` under two different seeds showed **every instruction and
operand identical** — only Tigress's internally-generated symbol *names*
differed, which do not affect compiled `.text` bytes at all. A full
20-variant campaign built this way came back as 19 exact duplicates of the
first variant under `.text`-hash deduplication, confirming the finding at
scale.

**Design 2 — K fixed transform combos × step 2's layout relink.** Compile
one obfuscated base per combo (§5's 5 validated transforms/combinations),
kept on disk, then generate volume within each combo by relinking that
base with step 2's proven layout-randomization mechanism (random function
order and padding, 0% duplication there) — the same "compile once, relink
many times" factoring step 2 uses. This worked, and a full campaign (150
variants, 5 combos × 30 layout seeds) produced 0% duplication with a
measurable, interpretable diversity structure between combos. But
comparing this axis's own Jaccard-distance numbers against step 1's and
step 2's on the same metric showed the volume/duplication-avoidance was
step 2's relink mechanism doing the work — Tigress's own contribution was
only 5 discrete "shapes" (one per combo), with `--Seed=` on top adding
nothing. Two of the five combos even showed **zero** functional-test
variance across all 30 of their layout seeds, underlining how shallow the
relink-driven variation was compared to the combo choice itself.

**Design 3 (current) — per-file random transform assignment.** Rather
than pick one fixed combo for an entire corpus build, each eligible `.c`
file independently gets one of the 5 validated transforms, chosen
deterministically from a hash of `(assignment_seed, file path)`. A given
variant is defined by its `assignment_seed` alone — no relink step
follows. This is a deliberate methodological choice, not an oversight:
the explicit goal of this design was to measure obfuscation's own
diversity contribution in isolation, so step 2's mechanism is dropped
entirely rather than layered on top, which would have muddied which axis
any measured diversity came from.

This turns Tigress's own contribution from 5 fixed points into a real
combinatorial space (5 raised to the eligible-file-count power), without
any new Tigress research — every ingredient (each of the 5 transforms
applied to each file) was already individually validated safe in §5, only
the *assignment granularity* changes, from "whole corpus" to "per file".
Mixing different transforms within one linked binary was validated safe
before committing to a full campaign: an 8-file sample with 4 different
transforms assigned across it compiled cleanly, kept every correctness
marker from §4 intact, and partial-linked together with zero symbol
clashes.

**Cost consequence, and the output cache.** Dropping relink means every
variant is once again its own full corpus compile — substantially more
expensive than design 2's "compile once per combo" model. This is
mitigated by an output cache keyed on `(file, assigned transform, compile
flags)`: since `TIGRESS_SEED` is fixed identically for every variant, two
different variants that happen to land on the same `(file, transform)`
pair — increasingly likely as the file's 5 possible outcomes get sampled
across more variants — produce byte-identical output, so the second
request is served from cache instead of re-running the whole
prep+Tigress+fixes+compile pipeline. This bounds the campaign's *unique*
Tigress work at roughly "5 full corpus passes, ever" regardless of how
many variants are generated, while keeping the combinatorial per-variant
diversity design 3 is built for. Measured on the real campaign reported
in `docs/step3_report.md`: a 73.7% cache hit rate across 25 variants.
Cache entries are published via a same-filesystem `cp`-to-temp-name plus
atomic `mv`, so a concurrent reader only ever sees a fully-absent or
fully-complete entry — no lock needed on the read path, and a rare
concurrent double-miss just costs redundant CPU once, not a correctness
risk, since the underlying computation is deterministic either way.

## 7. Known, accepted limitations

- **A residual set of `libc-test` failures is not chased to zero.**
  Consistent with this project's general approach (steps 1–2's baseline
  failures were also treated as pre-existing rather than debugged away),
  step 3's residual failures cluster into already-triaged categories from
  earlier feasibility testing: a small number of TLS/thread-bootstrap
  tests sensitive to the constructor-rename fix's execution timing
  relative to `ld.so`'s own bootstrap, a cluster of out-of-memory-pattern
  tests, and a handful of environment-sensitive tests unrelated to
  obfuscation. See `docs/step3_report.md` for the measured counts.
- **`Copy` widens the exported symbol surface.** Its duplicated helper
  functions are not currently marked hidden/internal, so they leak into
  the shared library's public dynamic symbol table. Not a correctness
  bug (functional tests pass), but a cleanliness gap worth closing before
  treating this transform as production-final.
- **Pure-assembly files are permanently out of reach for this axis.**
  `memcpy`/`memset`/`memmove` and other hot-path string functions are
  hand-written x86-64 assembly on this architecture, not C — no
  source-to-source C obfuscator can touch them. This is a real, permanent
  coverage gap in this axis, not something any transform choice can close.
