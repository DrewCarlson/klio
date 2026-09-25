// klio dispatchers for the upstream kotlinx-coroutines runtime.
// Each `runBlocking` owns a cooperative pump on its calling OS
// thread. `KlioDispatcher` posts work back onto that pump via
// `__kxco_spawn` (`Unconfined`, `Main`, internal delay continuations),
// and its delays and timeouts wait on that pump.
// `KlioDefaultDispatcher` posts each Runnable onto a real worker
// thread via `__kxco_dispatch`, so `async(Dispatchers.Default)` /
// `launch(Dispatchers.Default)` execute bodies in parallel; the
// worker's completion `resumeWith` routes back to the awaiter's
// pump through a cross-thread mailbox in the runtime. The Default
// and IO dispatchers' delays and timeouts wait on the timer thread
// (`__kxco_spawnTimer`), as the JVM's wait on `DefaultExecutor`, so a
// worker never waits out a timer it scheduled.

package kotlinx.coroutines

import kotlin.coroutines.*

internal fun __kxco_spawn(block: () -> Unit) {}
// Schedule a `withTimeout` cancellation gate. Distinct from `__kxco_spawn`
// so the host re-homes the gate onto the pump of the undispatched block it
// cancels (they share one timer queue), letting the earliest deadline fire.
internal fun __kxco_spawnTimeout(block: () -> Unit) {}
// Schedule `block` on the timer thread. A host without one schedules it as
// `__kxco_spawnTimeout` (`timeout`) or `__kxco_spawn` would.
internal fun __kxco_spawnTimer(timeout: Boolean, block: () -> Unit) {}
internal fun __kxco_delayMillis(millis: Long) {}
internal fun __kxco_dispatch(block: () -> Unit): Long = 0L
// `__kxco_dispatch` onto the elastic blocking-work view of the pool.
internal fun __kxco_dispatchIo(block: () -> Unit): Long = 0L
internal fun __kxco_newSlot(): Long = 0L
internal fun __kxco_parkSlot(slot: Long) {}
internal fun __kxco_armSlot(slot: Long) {}
internal fun __kxco_resumeSlot(slot: Long) {}
internal fun __kxco_systemProperty(name: String): String? = null
internal fun __kxco_pushScope(scope: Any?) {}
internal fun __kxco_popScope() {}
internal fun __kxco_rbPump(scope: Any?, block: () -> Unit) { block() }

// `runBlocking` — the blocking bridge between regular and suspending
// code. Mirrors the upstream JVM shape: a `BlockingCoroutine` job over
// the caller's context, the body started as its child, and the calling
// thread pumping the cooperative event loop until the coroutine's whole
// job tree completes. Children attach to the blocking job, a failing
// child cancels it per structured concurrency, and the final state —
// value or exception — surfaces here through the upstream completion
// machinery (`onCompleted` / `onCancelled`).
public fun <T> runBlocking(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T
): T {
    val newContext = if (context[ContinuationInterceptor] == null)
        GlobalScope.newCoroutineContext(context + KlioDispatcher)
    else
        GlobalScope.newCoroutineContext(context)
    val coroutine = KlioBlockingCoroutine<T>(newContext)
    return coroutine.joinBlocking(block)
}

private class KlioBlockingCoroutine<T>(
    parentContext: CoroutineContext
) : AbstractCoroutine<T>(parentContext, true, true) {
    private var result: Any? = null
    private var failure: Throwable? = null
    private var failed = false
    private var completionSlot: Long = 0L

    override fun onCompleted(value: T) {
        result = value
    }

    override fun onCancelled(cause: Throwable, handled: Boolean) {
        failed = true
        failure = cause
    }

    fun joinBlocking(block: suspend CoroutineScope.() -> T): T {
        __kxco_rbPump(this) {
            start(CoroutineStart.DEFAULT, this, block)
            if (!isCompleted) {
                completionSlot = __kxco_newSlot()
                invokeOnCompletion { __kxco_resumeSlot(completionSlot) }
                __kxco_parkSlot(completionSlot)
            }
        }
        if (failed) throw (failure ?: IllegalStateException("runBlocking job failed"))
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}

internal object KlioDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        // The dispatched segment runs with ITS coroutine as the active
        // scope (the startBlock bracket for undispatched bodies): anything
        // derived from the ambient scope — channel-cancellation arming,
        // `coroutineContext` — must name THIS coroutine, not whatever a
        // sibling activation leaked. The pop is skipped over a suspension
        // unwind (the delta capture owns the entry then) and runs when the
        // segment completes.
        val job = context[Job]
        __kxco_spawn {
            if (job != null) __kxco_pushScope(job)
            try {
                block.run()
            } finally {
                if (job != null) __kxco_popScope()
            }
        }
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>
    ) {
        __kxco_spawn {
            __kxco_delayMillis(timeMillis)
            continuation.resumeWith(Result.success(Unit))
        }
    }

    // `withTimeout` schedules the timeout through this. The default
    // `Delay.invokeOnTimeout` recurses into `DefaultDelay` (== this),
    // so it must be overridden: run `block` after `timeMillis` of
    // virtual time on the same cooperative pump, unless the returned
    // handle is disposed first (the timed body completed in time).
    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext
    ): DisposableHandle {
        val gate = TimeoutGate(block)
        __kxco_spawnTimeout {
            if (!gate.isDisposed()) {
                val slot = __kxco_newSlot()
                gate.bindSlot(slot)
                __kxco_armSlot(slot)
                __kxco_delayMillis(timeMillis)
                gate.fire()
            }
        }
        return gate
    }
}

// Real-thread CPU-bound dispatcher. `dispatch` posts each block onto
// the shared worker pool's Default view (parallelism `max(2, nproc)`)
// via `__kxco_dispatch`; multiple bodies under
// `async(Dispatchers.Default) { … }` execute in parallel through
// the loom-verified value model. Its delays and timeouts wait on the
// timer thread.
internal object KlioDefaultDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_dispatch { block.run() }
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>
    ) = scheduleTimerResume(timeMillis, continuation)

    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext
    ): DisposableHandle = scheduleTimerGate(timeMillis, block)
}

// Blocking-work dispatcher: the elastic view over the same worker pool
// as `KlioDefaultDispatcher` (parallelism `max(64, nproc)`, shared
// threads). A distinct object from the Default dispatcher so
// `withContext(Dispatchers.IO)` from a Default coroutine observes a
// dispatcher change, exactly as upstream.
internal object KlioIoDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_dispatchIo { block.run() }
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>
    ) = scheduleTimerResume(timeMillis, continuation)

    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext
    ): DisposableHandle = scheduleTimerGate(timeMillis, block)
}

// The pool dispatchers' `Delay`, which `limitedParallelism` views share:
// the wait runs on the timer thread, not on the worker that scheduled it.
// A dispatched task waiting out its own timer would hold its worker, and a
// `limitedParallelism(1)` view has only that worker to run the resume the
// timer dispatches, so the resume would wait for the timer's own end. A
// cancelled delay disposes its gate, which ends the wait at once.
private fun scheduleTimerResume(timeMillis: Long, continuation: CancellableContinuation<Unit>) {
    val gate = TimeoutGate(ResumeAfterDelay(continuation))
    __kxco_spawnTimer(false) {
        if (!gate.isDisposed()) {
            val slot = __kxco_newSlot()
            gate.bindSlot(slot)
            __kxco_armSlot(slot)
            __kxco_delayMillis(timeMillis)
            gate.fire()
        }
    }
    continuation.disposeOnCancellation(gate)
}

private fun scheduleTimerGate(timeMillis: Long, block: Runnable): DisposableHandle {
    val gate = TimeoutGate(block)
    __kxco_spawnTimer(true) {
        if (!gate.isDisposed()) {
            val slot = __kxco_newSlot()
            gate.bindSlot(slot)
            __kxco_armSlot(slot)
            __kxco_delayMillis(timeMillis)
            gate.fire()
        }
    }
    return gate
}

private class ResumeAfterDelay(private val continuation: CancellableContinuation<Unit>) : Runnable {
    override fun run() {
        continuation.resumeWith(Result.success(Unit))
    }
}

internal object KlioMainDispatcher : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher get() = this

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_spawn { block.run() }
    }
}

// The real upstream `Unconfined` object, aliased at file scope where the
// bare name cannot collide with the `Dispatchers.Unconfined` property.
// `isDispatchNeeded == false` is what makes a launch under it execute on
// the caller's stack up to the first suspension, and `yield()` under it
// return without suspending — the pump-backed KlioDispatcher advertised
// dispatch-needed and queued the body instead, so nothing ran eagerly.
private val klioUnconfined: CoroutineDispatcher = Unconfined

public actual object Dispatchers {
    public actual val Default: CoroutineDispatcher get() = KlioDefaultDispatcher
    public actual val Main: MainCoroutineDispatcher get() = injectedMainDispatcher ?: KlioMainDispatcher
    public actual val Unconfined: CoroutineDispatcher get() = klioUnconfined
    public val IO: CoroutineDispatcher get() = KlioIoDispatcher

    // `Dispatchers.setMain` installs kotlinx-coroutines-test's
    // TestMainDispatcher here and `resetMain` takes it back out, the same
    // seam every non-JVM target supplies.
    private var injectedMainDispatcher: MainCoroutineDispatcher? = null

    @PublishedApi
    internal fun injectMain(dispatcher: MainCoroutineDispatcher) {
        injectedMainDispatcher = dispatcher
    }
}

// Carries the timeout `block` and its cancelled state as instance
// members (not a lambda-captured local, which klio does not yet
// close over correctly inside an object-method's nested lambda). The
// scheduled spawn captures the gate instance and calls `fire()`;
// `withTimeout` disposes it when the body completes in time.
private class TimeoutGate(private val block: Runnable) : DisposableHandle {
    private var cancelled = false
    private var slot: Long = -1L
    fun isDisposed(): Boolean = cancelled
    fun bindSlot(s: Long) {
        slot = s
    }
    fun fire() {
        if (!cancelled) block.run()
    }
    override fun dispose() {
        cancelled = true
        // Wake the parked waiter NOW. Its timed park is bound to the slot
        // (armed before the delay), so this preempts the deadline; without
        // it the waiter is a zombie child holding the enclosing job tree —
        // and the pump — for the timeout's full real duration.
        if (slot >= 0L) __kxco_resumeSlot(slot)
    }
}
