// klio platform layer for kotlin.coroutines.intrinsics.
// See the sibling Actuals.kt header for the overall model.

package kotlin.coroutines.intrinsics

import kotlin.coroutines.Continuation
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.KlioContinuation
import kotlin.coroutines.__klio_co_newSlot
import kotlin.coroutines.__klio_co_armSlot
import kotlin.coroutines.__klio_co_disarmSlot
import kotlin.coroutines.__klio_co_park
import kotlin.coroutines.__klio_co_runRoot

// Obtains the current continuation and either suspends or returns a
// value immediately. klio model: hand the block a slot-backed
// continuation; if the block parks (returns COROUTINE_SUSPENDED),
// suspend on the slot and yield the resumed Result; otherwise the
// block's value is the result.
public fun <T> suspendCoroutineUninterceptedOrReturn(block: (Continuation<T>) -> Any?): T {
    val slot = __klio_co_newSlot()
    val cont = KlioContinuation<T>(slot, EmptyCoroutineContext)
    // Arm the slot before running the block: a suspension inside it
    // (e.g. a `delay` within `withTimeout`) is then bound to this
    // continuation's slot, so a cancellation can resume it early by
    // throwing instead of waiting out the timer.
    __klio_co_armSlot(slot)
    val outcome = block(cont)
    @Suppress("UNCHECKED_CAST")
    return if (outcome === COROUTINE_SUSPENDED) {
        __klio_co_park(slot).getOrThrow() as T
    } else {
        // Completed synchronously — drop the arm so it cannot bind a
        // later unrelated suspension.
        __klio_co_disarmSlot()
        outcome as T
    }
}

// Single-threaded klio has no interceptor unless one is installed in
// the continuation's context; mirror the upstream contract.
public fun <T> Continuation<T>.intercepted(): Continuation<T> {
    val interceptor = context[ContinuationInterceptor]
    return interceptor?.interceptContinuation(this) ?: this
}

// Running a `suspend` lambda is just invoking it: klio executes the
// body inline and parks cooperatively at suspension points. These
// route the lambda's terminal outcome to `completion`.
public fun <T> (suspend () -> T).createCoroutineUnintercepted(
    completion: Continuation<T>
): Continuation<Unit> {
    val block = this
    return KlioStartContinuation(completion) { block() }
}

public fun <R, T> (suspend R.() -> T).createCoroutineUnintercepted(
    receiver: R,
    completion: Continuation<T>
): Continuation<Unit> {
    val block = this
    return KlioStartContinuation(completion) { block(receiver) }
}

public fun <T> (suspend () -> T).startCoroutineUninterceptedOrReturn(
    completion: Continuation<T>
): Any? {
    val block = this
    return startBlock(completion) { block() }
}

public fun <R, T> (suspend R.() -> T).startCoroutineUninterceptedOrReturn(
    receiver: R,
    completion: Continuation<T>
): Any? {
    val block = this
    return startBlock(completion) { block(receiver) }
}

// Receiver lambda with one value parameter — the shape of a ktor
// `PipelineInterceptor` (`suspend PipelineContext<…>.(TSubject) -> Unit`).
// `pipelineStartCoroutineUninterceptedOrReturn`'s actual routes here.
public fun <R, P, T> (suspend R.(P) -> T).startCoroutineUninterceptedOrReturn(
    receiver: R,
    param: P,
    completion: Continuation<T>
): Any? {
    val block = this
    return startBlock(completion) { receiver.block(param) }
}

public fun <R, P, T> (suspend R.(P) -> T).createCoroutineUnintercepted(
    receiver: R,
    param: P,
    completion: Continuation<T>
): Continuation<Unit> {
    val block = this
    return KlioStartContinuation(completion) { receiver.block(param) }
}

internal fun <T> startBlock(completion: Continuation<T>, body: () -> T): Any? {
    // `startCoroutineUninterceptedOrReturn` semantics: run the
    // coroutine in the current activation and return its result
    // directly. The completion is NOT resumed here on synchronous
    // completion — the caller (e.g. `startUndispatched`) inspects the
    // returned value and drives the completion itself; resuming here
    // too would double-complete the Job. A synchronous throw
    // propagates so the caller can wrap it; a real suspension parks
    // cooperatively inside `body()` and the eventual resume routes
    // through the continuation klio captured at the suspension point.
    return body()
}

@PublishedApi
internal class KlioStartContinuation<T>(
    private val completion: Continuation<T>,
    private val body: () -> T
) : Continuation<Unit> {
    public override val context: CoroutineContext
        get() = completion.context

    public override fun resumeWith(result: Result<Unit>) {
        // Deliver the body's outcome to `completion` *inside* the
        // driver root: a suspension inside `body()` parks the whole
        // activation (including this pending completion delivery),
        // and the later resume drives it to the real result.
        val comp = completion
        val b = body
        __klio_co_runRoot {
            val r: Result<T> = try {
                Result.success(b())
            } catch (e: Throwable) {
                Result.failure(e)
            }
            comp.resumeWith(r)
        }
    }
}
