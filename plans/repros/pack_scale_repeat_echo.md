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
