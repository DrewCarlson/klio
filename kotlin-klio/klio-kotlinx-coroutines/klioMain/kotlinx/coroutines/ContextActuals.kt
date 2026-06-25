package kotlinx.coroutines

import kotlin.coroutines.*
import kotlinx.coroutines.internal.ScopeCoroutine

public actual fun CoroutineScope.newCoroutineContext(
    context: CoroutineContext
): CoroutineContext {
    val combined = coroutineContext + context
    // Match Kotlin/JVM: a coroutine launched with no explicit dispatcher (e.g.
    // GlobalScope.launch / CoroutineScope(Job()).launch outside a driver) runs
    // on Dispatchers.Default — dispatched to the worker pool with real
    // suspension — not eagerly inline. Inside runBlocking the context already
    // carries an interceptor, so this branch is not taken there.
    return if (combined[ContinuationInterceptor] == null)
        combined + Dispatchers.Default
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

// klio runs every `withContext` body on the same cooperative pump, so the
// undispatched coroutine is just a scope coroutine over the unchanged context.
internal actual class UndispatchedCoroutine<in T> actual constructor(
    context: CoroutineContext,
    uCont: Continuation<T>
) : ScopeCoroutine<T>(context, uCont)

internal actual val CoroutineContext.coroutineName: String?
    get() = this[CoroutineName]?.name

// klio's single cooperative dispatcher also serves as the default
// `Delay`: `withTimeout` / `delay` on a context without an explicit
// dispatcher resolve here, scheduling resumption on the same pump.
@Suppress("PropertyName")
internal actual val DefaultDelay: Delay = KlioDispatcher
