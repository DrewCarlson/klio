// klio's thread-pool contexts: `newFixedThreadPoolContext` and, through the
// common source, `newSingleThreadContext`. Each dispatcher owns a pool of
// real threads of its own, apart from `Dispatchers.Default`'s, named as the
// JVM names them: `name` for one thread, `name-1`, `name-2`, ... for more.
// Its delays and timeouts wait on the timer thread. `close` refuses further
// work and lets the queued tasks finish; the threads end once the queue
// drains. A task dispatched afterwards cancels its job and runs on
// `Dispatchers.IO` instead, as on the JVM, so its coroutine can clean up and
// complete. The pool's threads are daemons: one never closed ends with the
// run.

package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext

internal fun __kxco_poolNew(nThreads: Int, name: String): Long = 0L
internal fun __kxco_poolDispatch(pool: Long, block: () -> Unit): Boolean = true
internal fun __kxco_poolClose(pool: Long) {}

// The actual behind the common `expect` class. Without it the class had no
// constructor delegating to `CoroutineDispatcher`'s, so a subclass never set
// its context key, and `context + dispatcher` kept the old interceptor.
public actual abstract class CloseableCoroutineDispatcher actual constructor() : CoroutineDispatcher(), AutoCloseable {
    public actual abstract override fun close()
}

@DelicateCoroutinesApi
public actual fun newFixedThreadPoolContext(nThreads: Int, name: String): CloseableCoroutineDispatcher {
    require(nThreads >= 1) { "Expected at least one thread, but got: $nThreads" }
    return ThreadPoolDispatcher(nThreads, name)
}

private class ThreadPoolDispatcher(nThreads: Int, private val name: String) : CloseableCoroutineDispatcher(), Delay {
    private val pool: Long = __kxco_poolNew(nThreads, name)

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        if (__kxco_poolDispatch(pool) { block.run() }) return
        context.cancel(CancellationException("The task was rejected", IllegalStateException("Dispatcher $name was closed")))
        Dispatchers.IO.dispatch(context, block)
    }

    override fun scheduleResumeAfterDelay(timeMillis: Long, continuation: CancellableContinuation<Unit>) =
        scheduleTimerResume(timeMillis, continuation)

    override fun invokeOnTimeout(timeMillis: Long, block: Runnable, context: CoroutineContext): DisposableHandle =
        scheduleTimerGate(timeMillis, block)

    override fun close() {
        __kxco_poolClose(pool)
    }
}
