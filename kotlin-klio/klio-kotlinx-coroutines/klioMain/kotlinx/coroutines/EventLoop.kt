package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext

// klio actuals for the event-loop expects. Blocking work runs on the klio
// pump (see KlioRuntime.kt), so the thread-local event loop only ever
// serves the Dispatchers.Unconfined fast path: the EventLoop base class
// carries the whole unconfined queue, and this subclass exists to be
// instantiable. Anything that would need a real blocking loop reports
// itself, matching upstream's single-threaded platforms.

internal actual fun createEventLoop(): EventLoop = UnconfinedEventLoop()

internal actual fun nanoTime(): Long = unsupported()

internal class UnconfinedEventLoop : EventLoop() {
    override fun dispatch(context: CoroutineContext, block: Runnable): Unit = unsupported()
}

internal actual abstract class EventLoopImplPlatform : EventLoop() {
    protected actual fun unpark(): Unit = unsupported()

    protected actual fun reschedule(now: Long, delayedTask: EventLoopImplBase.DelayedTask): Unit =
        unsupported()
}

internal actual object DefaultExecutor {
    public actual fun enqueue(task: Runnable): Unit = unsupported()
}

private fun unsupported(): Nothing =
    throw UnsupportedOperationException("blocking event loop is not supported: klio runs coroutines on its own pump")

internal actual inline fun platformAutoreleasePool(crossinline block: () -> Unit) = block()
