package kotlinx.coroutines

import kotlin.coroutines.*

public actual fun CoroutineScope.newCoroutineContext(
    context: CoroutineContext
): CoroutineContext {
    val combined = coroutineContext + context
    return if (combined[ContinuationInterceptor] == null)
        combined + KlioDispatcher
    else combined
}

@InternalCoroutinesApi
public actual fun CoroutineContext.newCoroutineContext(
    addedContext: CoroutineContext
): CoroutineContext = this + addedContext

internal actual inline fun <T> withCoroutineContext(
    context: CoroutineContext,
    countOrElement: Any?,
    block: () -> T
): T = block()

internal actual inline fun <T> withContinuationContext(
    continuation: Continuation<*>,
    countOrElement: Any?,
    block: () -> T
): T = block()

internal actual fun Continuation<*>.toDebugString(): String = toString()

internal actual val CoroutineContext.coroutineName: String?
    get() = this[CoroutineName]?.name

// klio's single cooperative dispatcher also serves as the default
// `Delay`: `withTimeout` / `delay` on a context without an explicit
// dispatcher resolve here, scheduling resumption on the same pump.
@Suppress("PropertyName")
internal actual val DefaultDelay: Delay = KlioDispatcher
