// klio dispatchers for the upstream kotlinx-coroutines runtime.
// Each `runBlocking` owns a cooperative pump on its calling OS
// thread. `KlioDispatcher` posts work back onto that pump via
// `__kxco_spawn` (`Unconfined`, `Main`, internal delay continuations).
// `KlioDefaultDispatcher` posts each Runnable onto a real worker
// thread via `__kxco_dispatch`, so `async(Dispatchers.Default)` /
// `launch(Dispatchers.Default)` execute bodies in parallel; the
// worker's completion `resumeWith` routes back to the awaiter's
// pump through a cross-thread mailbox in the runtime. Delay
// scheduling stays on the cooperative virtual clock through
// `__kxco_spawn`.

package kotlinx.coroutines

import kotlin.coroutines.*

internal fun __kxco_spawn(block: () -> Unit) {}
internal fun __kxco_delayMillis(millis: Long) {}
internal fun __kxco_dispatch(block: () -> Unit): Long = 0L

internal object KlioDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_spawn { block.run() }
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
        __kxco_spawn {
            __kxco_delayMillis(timeMillis)
            gate.fire()
        }
        return gate
    }
}

// Real-thread CPU-bound dispatcher. `dispatch` posts each block
// onto a worker thread via `__kxco_dispatch`; multiple bodies under
// `async(Dispatchers.Default) { … }` execute in parallel through
// the loom-verified value model. Delay scheduling stays on the
// cooperative virtual clock by routing through `__kxco_spawn`.
internal object KlioDefaultDispatcher : CoroutineDispatcher(), Delay {
    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_dispatch { block.run() }
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

    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext
    ): DisposableHandle {
        val gate = TimeoutGate(block)
        __kxco_spawn {
            __kxco_delayMillis(timeMillis)
            gate.fire()
        }
        return gate
    }
}

internal object KlioMainDispatcher : MainCoroutineDispatcher() {
    override val immediate: MainCoroutineDispatcher get() = this

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        __kxco_spawn { block.run() }
    }
}

public actual object Dispatchers {
    public actual val Default: CoroutineDispatcher get() = KlioDefaultDispatcher
    public actual val Main: MainCoroutineDispatcher get() = KlioMainDispatcher
    public actual val Unconfined: CoroutineDispatcher get() = KlioDispatcher
    public val IO: CoroutineDispatcher get() = KlioDefaultDispatcher
}

// Carries the timeout `block` and its cancelled state as instance
// members (not a lambda-captured local, which klio does not yet
// close over correctly inside an object-method's nested lambda). The
// scheduled spawn captures the gate instance and calls `fire()`;
// `withTimeout` disposes it when the body completes in time.
private class TimeoutGate(private val block: Runnable) : DisposableHandle {
    private var cancelled = false
    fun fire() {
        if (!cancelled) block.run()
    }
    override fun dispose() {
        cancelled = true
    }
}
