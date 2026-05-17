// Bespoke klio platform layer: coroutine-context helpers. klio runs
// one cooperative thread, so there is no thread-context save/restore
// and no dispatcher interception to thread through — the `with*`
// helpers just run the block. `newCoroutineContext` folds the added
// context in (no platform Default dispatcher injection: klio's
// scheduler is the single execution context).

package kotlinx.coroutines

import kotlin.coroutines.*

public actual fun CoroutineScope.newCoroutineContext(
    context: CoroutineContext
): CoroutineContext = coroutineContext + context

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
