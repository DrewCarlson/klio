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
    // The continuation carries the suspending coroutine's real context
    // (the suspend-implicit `coroutineContext`, resolved by the host to
    // the active coroutine), not an empty one: cancellable suspensions
    // read `context[Job]` to install their parent-cancellation handle,
    // which is how `Job.cancel` preempts a parked `delay`/`join`.
    val cont = KlioContinuation<T>(slot, coroutineContext)
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

// klio installs no implicit interceptor; one applies only when the
// continuation's context carries it. Mirrors the upstream contract.
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
    return KlioStartContinuation(completion) { receiver.block() }
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
    return startBlock(completion) { receiver.block() }
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
    //
    // The block belongs to `completion`'s coroutine (a `ScopeCoroutine`
    // / `TimeoutCoroutine`): making it the active scope lets the
    // suspend-implicit `coroutineContext` inside resolve to that
    // coroutine's context, so a cancellable suspension installs its
    // parent-cancellation handle on the right Job — `withTimeout`'s
    // expiry preempts the block's `delay` through exactly that handle.
    // A suspension unwinding out of `body()` skips the `finally` (the
    // activation is parked, not failed); the pop then runs when the
    // resumed body finally completes, and the driving pump truncates
    // any push left by an activation abandoned mid-park.
    //
    // The body ALWAYS becomes its own activation, enclosing pump or not.
    // `startCoroutineUninterceptedOrReturn` owes its caller COROUTINE_SUSPENDED
    // when the body suspends, so the caller can carry on — and klio PARKS an
    // activation rather than unwinding it, so running `body()` inline under an
    // enclosing pump parked the CALLER along with it and the call never returned.
    // `runTest` starts its test body UNDISPATCHED and only THEN launches the
    // coroutine that drives `TestCoroutineScheduler`; with the caller parked that
    // driver was never launched, so every test needing the scheduler — every
    // `join`, `coroutineScope`, `withContext` awaiting a child — deadlocked.
    //
    // `__klio_co_startRootOrSuspended` runs the body as its own root, drives it to
    // quiescence, and reports a still-parked body as COROUTINE_SUSPENDED. Because
    // the caller's frames then move on (they were NOT captured by the park), the
    // resumed tail must deliver the eventual result to `completion` itself. The
    // `suspended` flag is written after the start returns and read by the tail
    // after the resume: the captured cell makes the async case (and only it)
    // resume the completion, keeping the synchronous no-double-complete contract.
    var suspended = false
    val r = __klio_co_startRootOrSuspended(completion) {
        __klio_co_pushScope(completion)
        try {
            val v = body()
            if (suspended) completion.resumeWith(Result.success(v))
            v
        } catch (e: Throwable) {
            if (!suspended) throw e
            completion.resumeWith(Result.failure(e))
            null
        } finally {
            __klio_co_popScope()
        }
    }
    if (r === kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED) suspended = true
    return r
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
        __klio_co_runRoot(comp) {
            val r: Result<T> = try {
                Result.success(b())
            } catch (e: Throwable) {
                Result.failure(e)
            }
            comp.resumeWith(r)
        }
    }
}
