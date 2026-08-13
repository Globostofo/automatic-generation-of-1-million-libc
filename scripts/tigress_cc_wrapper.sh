#!/bin/bash
# =============================================================================
# Script   : tigress_cc_wrapper.sh
# Purpose  : CC substitute for building musl (step 3, palier 4 production
#            pipeline). For each single-source `-c` compile of a .c file,
#            obfuscates it via Tigress before handing it to the real
#            compiler, applying the systematic fixes validated at palier 2-4:
#              1. sanitize C99 `[static N]` array-parameter syntax
#              2. filter GCC clone symbols (dotted names) out of --Functions=
#              3. append a stub main(), then rename Tigress's generated
#                 main() into a __attribute__((constructor)) function instead
#                 of stripping it, so static/global initializers still run
#              4. strip the wrongly-added hidden visibility Tigress puts on
#                 weak_alias(...) trampoline targets
#            Anything that isn't a single .c -c compile (linking, .s assembly,
#            multi-source invocations) passes straight through untouched.
#            On ANY failure at ANY stage, falls back to compiling the
#            original, unmodified source and logs the reason -- this is what
#            lets a "full build" attempt run unattended instead of requiring
#            per-file manual triage.
#
#            TWO-PHASE / cached design (palier 4 campaign architecture): the
#            reference-compile + preprocess + [static N] fix + stub-main step
#            is identical for every variant of a given file -- only the
#            Tigress transform itself varies with --Seed=. So that prep work
#            is cached once, shared across every variant build, instead of
#            being redone from scratch per file per variant:
#              TIGRESS_PHASE=prep    populate the shared cache for this file,
#                                    then compile the ORIGINAL unmodified
#                                    source (no transform) -- used by
#                                    15_build_base_tigress.sh to warm the
#                                    cache once and produce an unobfuscated
#                                    baseline build as a side effect.
#              TIGRESS_PHASE=variant (default) reuse the cached prep for this
#                                    file if present (falls back to doing it
#                                    fresh if not, so this script still works
#                                    standalone without a prior prep pass),
#                                    then run the real Tigress transform with
#                                    --Seed=$TIGRESS_SEED and compile.
# Usage    : used as CC=/path/to/tigress_cc_wrapper.sh during ./configure
#            Env vars:
#              REALCC             actual compiler to invoke (default: gcc)
#              TIGRESS_TRANSFORM  comma-separated --Transform= chain
#                                 (default: Flatten,Split)
#              TIGRESS_SEED       --Seed= value for the transform chain
#                                 (required in TIGRESS_PHASE=variant unless
#                                 TIGRESS_EXTRA_ARGS already sets one)
#              TIGRESS_EXTRA_ARGS additional tigress flags, e.g.
#                                 --Environment=x86_64:Linux:Gcc:4.6
#              TIGRESS_PHASE      prep | variant (default: variant)
#              TIGRESS_BASE_CACHE shared, cross-variant cache dir for the
#                                 prep step (default: /tmp/tigress_base_cache)
#              TIGRESS_TMP        per-build scratch dir, NOT shared across
#                                 variants (default: /tmp/tigress_wrap)
#              TIGRESS_REPORT     coverage log path (default: $TIGRESS_TMP/report.txt)
#              TIGRESS_EXCLUDES   optional file, one exact source path per
#                                 line (as it appears in the compile command)
#                                 to always pass through unobfuscated
# =============================================================================

set -u

REALCC="${REALCC:-gcc}"
TIGRESS_EXTRA_ARGS="${TIGRESS_EXTRA_ARGS:-}"
TIGRESS_PHASE="${TIGRESS_PHASE:-variant}"
TIGRESS_SEED="${TIGRESS_SEED:-}"
TIGRESS_TMP="${TIGRESS_TMP:-/tmp/tigress_wrap}"
TIGRESS_BASE_CACHE="${TIGRESS_BASE_CACHE:-/tmp/tigress_base_cache}"
TIGRESS_REPORT="${TIGRESS_REPORT:-$TIGRESS_TMP/report.txt}"
TIGRESS_EXCLUDES="${TIGRESS_EXCLUDES:-}"

mkdir -p "$TIGRESS_TMP" "$TIGRESS_BASE_CACHE"

ARGS=("$@")
SRC=""
OUT=""
IS_COMPILE=0
NUM_C=0

for ((i = 0; i < ${#ARGS[@]}; i++)); do
    a="${ARGS[$i]}"
    case "$a" in
        -c) IS_COMPILE=1 ;;
        -o) OUT="${ARGS[$((i + 1))]}" ;;
        *.c) SRC="$a"; NUM_C=$((NUM_C + 1)) ;;
    esac
done

passthrough() {
    exec "$REALCC" "${ARGS[@]}"
}

# Only intercept single-source compiles of a .c file with an explicit -o.
# Everything else (linking the final .so, assembling .s files, anything
# unusual) is not our concern here.
if [ "$IS_COMPILE" -ne 1 ] || [ "$NUM_C" -ne 1 ] || [ -z "$SRC" ] || [ -z "$OUT" ]; then
    passthrough
fi

if [ -n "$TIGRESS_EXCLUDES" ] && [ -f "$TIGRESS_EXCLUDES" ] && grep -qxF "$SRC" "$TIGRESS_EXCLUDES"; then
    passthrough
fi

SAFE="$(echo "$SRC" | tr '/' '_')"
WORK="$TIGRESS_TMP/$SAFE"
CACHE="$TIGRESS_BASE_CACHE/$SAFE"
mkdir -p "$WORK"
LOCK="$TIGRESS_TMP/.report.lock"

log_result() {
    ( flock 9; echo "$1 $SRC $2" >> "$TIGRESS_REPORT" ) 9> "$LOCK"
}

fallback() {
    log_result "FALLBACK" "$1"
    exec "$REALCC" "${ARGS[@]}"
}

# Args with -c/-o/$OUT/$SRC stripped out, reused for the reference compile,
# the preprocess step, and the final compile (each re-adds what it needs).
BASE_ARGS=()
for ((i = 0; i < ${#ARGS[@]}; i++)); do
    a="${ARGS[$i]}"
    [ "$a" = "-c" ] && continue
    [ "$a" = "-o" ] && { i=$((i + 1)); continue; }
    [ "$a" = "$OUT" ] && continue
    [ "$a" = "$SRC" ] && continue
    BASE_ARGS+=("$a")
done

# --- Prep: reference compile + preprocess + [static N] fix + stub main,
#     cached under $TIGRESS_BASE_CACHE/$SAFE so every variant build reuses
#     it instead of redoing identical, seed-independent work. ---
do_prep() {
    # 1. Reference compile: needed only to nm a function list for
    #    --Functions= with GCC-synthesized clone symbols (e.g. `pad.part.0`)
    #    filtered out -- including those makes tigress fail with
    #    ERR-BAD-REQUEST,NO-SUCH-FUNC.
    "$REALCC" "${BASE_ARGS[@]}" -c -o "$WORK/ref.o" "$SRC" 2> "$WORK/ref.log" \
        || return 1
    FUNCS=$(nm "$WORK/ref.o" 2> /dev/null | awk '($2 == "T" || $2 == "t") && $3 !~ /\./ {print $3}' | paste -sd, -)
    [ -n "$FUNCS" ] || return 2

    # 2. Preprocess (Tigress consumes preprocessed C, not raw sources).
    "$REALCC" "${BASE_ARGS[@]}" -E -o "$WORK/src.i" "$SRC" 2> "$WORK/pp.log" \
        || return 3

    # 3. Sanitize C99 `[static N]` array-parameter syntax -- not supported by
    #    Tigress's parser, semantically inert (always decays to a plain
    #    pointer per C99 6.7.5.3), confirmed safe on musl's occurrences at
    #    palier 2.
    sed -E 's/\[static ([^]]+)\]/[\1]/g' "$WORK/src.i" > "$WORK/src.fixed.i"

    # 4. Tigress is a whole-program obfuscator and errors on any input
    #    lacking main() -- append a stub. (Do NOT strip main after the fact
    #    instead -- see the ctor-rename step below for why that silently
    #    corrupts global initializers.)
    printf '\nint main(void){return 0;}\n' >> "$WORK/src.fixed.i"

    mkdir -p "$CACHE"
    cp "$WORK/src.fixed.i" "$CACHE/src.fixed.i"
    echo "$FUNCS" > "$CACHE/funcs.txt"
    return 0
}

if [ "$TIGRESS_PHASE" = "prep" ]; then
    do_prep
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            1) log_result "PREP-FALLBACK" "reference-compile-failed" ;;
            2) log_result "PREP-FALLBACK" "no-functions-found" ;;
            3) log_result "PREP-FALLBACK" "preprocess-failed" ;;
        esac
        exec "$REALCC" "${ARGS[@]}"
    fi
    log_result "PREP-OK" "-"
    # Prep mode compiles the ORIGINAL source, unobfuscated -- this doubles as
    # a correctness baseline build and lets `make` finish successfully while
    # warming the cache for every file in one pass.
    exec "$REALCC" "${BASE_ARGS[@]}" -c -o "$OUT" "$SRC"
fi

# --- Variant mode: reuse cached prep if present, else do it fresh. ---
if [ -s "$CACHE/src.fixed.i" ] && [ -s "$CACHE/funcs.txt" ]; then
    cp "$CACHE/src.fixed.i" "$WORK/src.fixed.i"
    FUNCS=$(cat "$CACHE/funcs.txt")
else
    do_prep
    rc=$?
    case "$rc" in
        1) fallback "reference-compile-failed" ;;
        2) fallback "no-functions-found" ;;
        3) fallback "preprocess-failed" ;;
    esac
fi

[ -n "${TIGRESS_SEED:-}" ] || fallback "no-seed-set"

# 5. Run Tigress as a chain of passes. Default tier-1 combo is Flatten+Split
#    -- both purely structural (control-flow rewrite, function splitting),
#    neither needs InitOpaque's runtime opaque-predicate support library.
#    That matters: InitOpaque's generated constructor runs at .init_array
#    time, which is *after* ld.so's own internal bootstrap use of malloc
#    (musl's ld.so *is* libc.so) -- a statically-initialized table needed
#    that early (e.g. mallocng's size_classes[]) stays zeroed when Tigress
#    turns its init into constructor code instead of true static data,
#    causing a stack-overflow crash (infinite alloc_group/alloc_slot
#    recursion) and, once that file's excluded, a separate ld.so deadlock
#    (do_init_fini holds a lock for the whole constructor-running window;
#    ~1200 extra per-file constructors make that window long enough to hit
#    a race normally too narrow to trigger). Confirmed via a full-corpus
#    run + gdb backtraces with EncodeArithmetic in the mix (which, like
#    AddOpaque/EncodeLiterals, needs InitOpaque) -- not fixed, tracked as a
#    real limitation requiring true static-initializer reconstruction
#    instead of the constructor-rename fix, not attempted. Split/Inline
#    confirmed to need no InitOpaque at all, sidestepping the whole bug
#    class rather than fixing it -- this is why they're the default.
#    Set TIGRESS_USE_INIT_OPAQUE=1 to re-enable the InitOpaque prefix stage
#    if a transform in TIGRESS_TRANSFORM needs it (e.g. EncodeArithmetic) --
#    accept the risk above knowingly, don't enable by default.
#    InitOpaque quirk if ever re-enabled: accepts EXACTLY ONE function in
#    --Functions=, never more (more causes a confusing opaque
#    ERR-BAD-REQUEST,TRANSFORM-MUST-NOT-BE-PRECEDED-BY regardless of which
#    functions); the stub main is always present and unique, target that.
TRANSFORM_LIST="${TIGRESS_TRANSFORM:-Flatten,Split}"

STAGE_IN="$WORK/src.fixed.i"
STAGE_NUM=0
if [ "${TIGRESS_USE_INIT_OPAQUE:-0}" = "1" ]; then
    tigress $TIGRESS_EXTRA_ARGS --Seed="$TIGRESS_SEED" \
        --Transform=InitOpaque --Functions=main --InitOpaqueStructs=list,array \
        --out="$WORK/src.stage0.c" "$WORK/src.fixed.i" \
        > "$WORK/tigress.log" 2>&1 \
        || fallback "tigress-failed"
    [ -s "$WORK/src.stage0.c" ] || fallback "tigress-empty-output"
    STAGE_IN="$WORK/src.stage0.c"
else
    : > "$WORK/tigress.log"
fi

IFS=',' read -ra STAGES <<< "$TRANSFORM_LIST"
for t in "${STAGES[@]}"; do
    STAGE_NUM=$((STAGE_NUM + 1))
    STAGE_OUT="$WORK/src.stage${STAGE_NUM}.c"
    tigress $TIGRESS_EXTRA_ARGS --Seed="$TIGRESS_SEED" --Transform="$t" --Functions="$FUNCS" \
        --out="$STAGE_OUT" "$STAGE_IN" \
        >> "$WORK/tigress.log" 2>&1 \
        || fallback "tigress-failed"
    [ -s "$STAGE_OUT" ] || fallback "tigress-empty-output"
    STAGE_IN="$STAGE_OUT"
done
cp "$STAGE_IN" "$WORK/src.tig.c"

# 6a. musl declares many public ABI functions via weak_alias(old, new) --
#     e.g. weak_alias(__pthread_mutex_lock, pthread_mutex_lock), where `new`
#     is meant to keep default (exported) visibility. Tigress turns this into
#     a real trampoline function for `new` that calls `old`, which is
#     functionally fine, but it marks that trampoline
#     __attribute__((__visibility__("hidden"))) instead of default --
#     silently dropping the public symbol from the .so's dynamic symbol
#     table even though the file compiles and Tigress reports success. Fix:
#     detect weak_alias `new` names from the pre-Tigress preprocessed
#     source, then strip the wrongly-added hidden visibility attribute off
#     those specific names in Tigress's output.
# 6b. Tigress rewrites every statically-initialized global/static into
#    individual runtime assignments placed inside its generated main() rather
#    than a normal C initializer. If main() never runs, those globals stay
#    zero-initialized -- a silent correctness bug, not a build failure.
#    Fix: rename the generated main() (both its definition, and its forward
#    declaration if Tigress emitted one) into a constructor function, so it
#    still runs automatically at load time via .init_array. `return 0;` must
#    become `return;` inside that function's body (a void function can't
#    return a value), which we do via brace-matching, not a blind sed, so we
#    don't clobber unrelated `return 0;` statements elsewhere in the file.
python3 - "$WORK/src.fixed.i" "$WORK/src.tig.c" "$WORK/src.ctor.c" << 'PYEOF'
import re
import sys

pre_src, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]

pre_text = open(pre_src).read()
alias_pat = re.compile(
    r"(\w+)\s*__attribute__\(\(\s*(?:weak|__weak__)\s*,\s*(?:alias|__alias__)\(\s*\"([^\"]+)\"\s*\)\s*\)\)"
)
public_alias_names = {m.group(1) for m in alias_pat.finditer(pre_text)}

text = open(src).read()

for name in public_alias_names:
    text = re.sub(
        r'__attribute__\(\(__visibility__\("hidden"\)\)\)(\s+)\b' + re.escape(name) + r"\b",
        r"\1" + name,
        text,
    )

pat = re.compile(r"\bint\s+main\s*\(([^)]*)\)")
matches = list(pat.finditer(text))

if not matches:
    open(dst, "w").write(text)
    sys.exit(0)

NAME = "tigress_ctor_init"


def find_body_end(text, brace_open_idx):
    depth = 0
    i = brace_open_idx
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


# Process matches back-to-front so earlier offsets in `text` stay valid as we
# splice replacements in.
for m in reversed(matches):
    header = f"__attribute__((constructor)) static void {NAME}({m.group(1)})"
    after = text[m.end():].lstrip()
    if after.startswith("{"):
        brace_idx = text.index("{", m.end())
        body_end = find_body_end(text, brace_idx)
        if body_end == -1:
            continue
        body = text[brace_idx:body_end + 1]
        body = re.sub(r"return\s*\(?\s*0\s*\)?\s*;", "return;", body)
        text = text[:m.start()] + header + body + text[body_end + 1:]
    else:
        # forward declaration only -- rewrite the header, keep trailing ';'
        text = text[:m.start()] + header + text[m.end():]

open(dst, "w").write(text)
PYEOF

[ -s "$WORK/src.ctor.c" ] || fallback "ctor-rename-failed"

# 7. Final compile of the obfuscated + fixed source, into the object file
#    the build actually asked for.
"$REALCC" "${BASE_ARGS[@]}" -c -o "$OUT" "$WORK/src.ctor.c" 2> "$WORK/final.log" \
    || fallback "final-compile-failed"

log_result "OK" "-"
