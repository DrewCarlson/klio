# `"A".repeat(4)` returns "A" — only with ALL SIX packs installed

Repro (deterministic):

    H=/tmp/fresh; rm -rf $H
    for p in kotlin.test kotlinx.atomicfu kotlinx.io kotlinx.coroutines \
             kotlinx.serialization io.ktor; do
      KLIO_HOME=$H klio pack install target/packs/$p-*.klio-pack
    done
    KLIO_HOME=$H klio run rep4.kt     # import io.ktor.utils.io.*
                                      # "A".repeat(4) -> "A" (length 1)

Leave ANY ONE of the six out -> "AAAA" (correct). Also correct with a
fresh empty home (embedded fallback). Rebuilding the packs with the
current binary does NOT fix it; clearing the home cache does not either.

Observed: the call statically binds `kotlin.text.repeat#<fid>` (the
TextH.kt expect header) and `[fn-entry]` shows a frame for that fid
ENTERING with this="A", n=4 — but the executed body receiver-echoes (the
klio TextActuals body would return "AAAA"; `string_repeat` intrinsic is
never invoked — verified with a debug print). Hypothesis: at full pack
load the func-id table collides/rebases so the fid resolves to a
different pack's one-arg echo-shaped body (the "bakes are not
cross-process id-stable" trap, now INTRA-process at load scale).

Downstream: ReadLineTest "limit - exceeding limit after several buffers"
and ReadUtf8LineTest "test reading line exceeding limit" fail in the
ktor census home exactly because `"A".repeat(1024)` collapses to "A"
(the writer emits 10 bytes; TooLongLineException never fires).

## Mechanism (dug 2026-08-15, session 2)

The chain, verified with [switch]/[bare]/[cmg] traces:

1. With >= 6 packs installed the stdlib base RE-LOWERS TextActuals.kt from
   source in-process (fresh/5-pack homes hit it too when the cache is
   cleared — the re-lower itself is fine there).
2. In `CharSequence.repeat`'s else-branch, `String(CharArray(n) { char })`
   lowers a bare call `String(...)`. Simple-name candidates at that site =
   ONLY `io.ktor.utils.io.core.String#...` (4-param); the stdlib
   `kotlin.text.String(CharArray)` expects are not in the candidate list.
   The pick is NONE in every configuration.
3. What differs at 6 packs: `shadowed_by_class` = `classIdIndexed("String",
   kotlin.text, <file>)` returns NULL (it is non-null at <= 5 packs). With
   the class shadow, the emit takes the constructor route and the runtime
   String(CharArray) machinery works (AAAA). Without it, the call emits a
   receiver-walk CMG that dispatches `String` as a MEMBER on the "A"
   receiver and returns the receiver ("A").
4. So the ROOT is the CLASS-INDEX lookup: at full pack load
   `classIdIndexed("String")` loses the builtin `kotlin.String` entry
   (tier or candidate-set drop — the exact layer inside
   `classNameCandidates`/`scopeTier` is the next probe).

Executed body is IDENTICAL in both configs (KLIO_DUMP_FN diff = fid/file
renumbering only); Switch decisions identical (n=4 -> else, length=1 ->
CharArray arm). The divergence is purely the `String(...)` bare-call emit.

Next probe: dump `classNameCandidates("String")` + each candidate's
scopeTier at the f-TextActuals lowering site in the all-6 home.

## RESOLVED (same session)

Final root: `shadowedByClass`'s factory-competition loops iterated the
GLOBAL `func_index` with no scope filter, so io.ktor's unimported
`fun String(bytes, offset, length, charset)` counted as an applicable
same-named factory for `String(chars)` written in kotlin.text — but only
when pack-load ORDER had registered it before the stdlib re-lower (hence
the all-six-packs trigger; fewer packs changed the order). kotlinc never
considers an out-of-scope factory. Fix: both loops now skip candidates
with `scopeTier > 3` for the CALL SITE's package/file. Verified:
`"A".repeat(4)` = AAAA in the all-six home (cold), ReadLineTest 25/25,
ReadUtf8LineTest 5/5. The earlier block-cache key hardening
((ptr,len,sig) fingerprint) stays as defense. CoroutinesTest's
writer/reader deadlock is unrelated and still open (#31).
