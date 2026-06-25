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
