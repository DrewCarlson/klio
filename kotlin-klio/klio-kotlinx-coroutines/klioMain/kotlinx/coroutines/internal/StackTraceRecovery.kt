// Bespoke klio platform layer: klio does not synthesize coroutine
// stack-trace recovery (single cooperative interpreter; the real
// call stack is the interpreter's). Recovery is identity.

package kotlinx.coroutines.internal

import kotlin.coroutines.*

internal actual fun <E : Throwable> recoverStackTrace(exception: E, continuation: Continuation<*>): E =
    exception

@Suppress("EXTENSION_SHADOWED_BY_MEMBER")
internal actual fun Throwable.initCause(cause: Throwable) {
    // klio Throwable carries its cause via the constructor / cause
    // chain already; nothing to backfill here.
}

internal actual fun <E : Throwable> recoverStackTrace(exception: E): E = exception

@Suppress("NOTHING_TO_INLINE")
internal actual suspend inline fun recoverAndThrow(exception: Throwable): Nothing =
    throw exception

internal actual fun <E : Throwable> unwrap(exception: E): E = exception

internal actual class StackTraceElement

internal actual interface CoroutineStackFrame {
    public actual val callerFrame: CoroutineStackFrame?
    public actual fun getStackTraceElement(): StackTraceElement?
}
