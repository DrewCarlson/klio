// Host-intrinsic entrypoints for androidx.compose.runtime.
//
// Each declaration's body is the not-installed fallback; the interpreter routes
// the FQN to the matching Zig implementation in src/compose_runtime when the
// pack is loaded (see HostBindings registration). klioMain `actual`s call these
// for the few operations that require the host (object identity, a global id
// counter, a monotonic clock, stderr logging).

package androidx.compose.runtime

internal fun __compose_identityHashCode(instance: Any?): Int =
    error("intrinsic androidx.compose.runtime.__compose_identityHashCode not installed")

internal fun __compose_nextStateId(): Long =
    error("intrinsic androidx.compose.runtime.__compose_nextStateId not installed")

internal fun __compose_monotonicNanos(): Long =
    error("intrinsic androidx.compose.runtime.__compose_monotonicNanos not installed")

internal fun __compose_logError(message: String, error: Throwable?): Unit =
    error("intrinsic androidx.compose.runtime.__compose_logError not installed")

// Implicit-composer stack (implemented in src/interp_ir/vm/compose.zig). The
// `Composition` pushes its composer around the content lambda; the call
// dispatcher and `currentComposer` read the stack head.
internal fun __compose_pushComposer(composer: Any?): Unit =
    error("intrinsic androidx.compose.runtime.__compose_pushComposer not installed")

internal fun __compose_popComposer(): Unit =
    error("intrinsic androidx.compose.runtime.__compose_popComposer not installed")

internal fun __compose_currentComposer(): Any? =
    error("intrinsic androidx.compose.runtime.__compose_currentComposer not installed")
