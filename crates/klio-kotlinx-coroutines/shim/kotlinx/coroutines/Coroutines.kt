// Klio shim for kotlinx.coroutines.
//
// The klio interpreter implements the core suspend / runBlocking /
// Continuation primitives (see crates/klio-interp/src/lib.rs:5068);
// this shim adds the higher-level kotlinx.coroutines API surface
// on top. Because klio is single-threaded, all dispatchers fold
// into the calling thread and `launch` / `async` execute their
// blocks eagerly to completion.

package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

interface Job {
    val isActive: Boolean
    val isCompleted: Boolean
    val isCancelled: Boolean
    fun cancel(): Unit
    suspend fun join(): Unit
}

class CompletableJob internal constructor() : Job {
    private var _active: Boolean = true
    private var _cancelled: Boolean = false

    override val isActive: Boolean get() = _active && !_cancelled
    override val isCompleted: Boolean get() = !_active
    override val isCancelled: Boolean get() = _cancelled

    override fun cancel() {
        _cancelled = true
        _active = false
    }

    override suspend fun join() {
        // klio runs the launch block to completion synchronously, so
        // by the time anyone can call join() the work is done.
    }

    internal fun markCompleted() { _active = false }
}

class Deferred<T> internal constructor(private val value: T) : Job {
    override val isActive: Boolean = false
    override val isCompleted: Boolean = true
    override val isCancelled: Boolean = false
    override fun cancel() {}
    override suspend fun join() {}
    suspend fun await(): T = value
}

interface CoroutineScope {
    val coroutineContext: CoroutineContext
}

object GlobalScope : CoroutineScope {
    override val coroutineContext: CoroutineContext get() = EmptyCoroutineContext
}

class CoroutineScopeImpl internal constructor(
    override val coroutineContext: CoroutineContext,
) : CoroutineScope

fun CoroutineScope(context: CoroutineContext): CoroutineScope = CoroutineScopeImpl(context)

abstract class CoroutineDispatcher

object Dispatchers {
    val Default: CoroutineDispatcher = object : CoroutineDispatcher() {}
    val Main: CoroutineDispatcher = object : CoroutineDispatcher() {}
    val IO: CoroutineDispatcher = object : CoroutineDispatcher() {}
    val Unconfined: CoroutineDispatcher = object : CoroutineDispatcher() {}
}

// Single-threaded klio: launch runs its block immediately on the
// current call stack. The returned CompletableJob is already
// completed by the time launch() returns.
fun CoroutineScope.launch(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> Unit,
): Job {
    val job = CompletableJob()
    runBlocking { block(this) }
    job.markCompleted()
    return job
}

fun <T> CoroutineScope.async(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T,
): Deferred<T> {
    val result: T = runBlocking { block(this) }
    return Deferred(result)
}

// `delay` busy-waits via the host clock to avoid pulling in real
// scheduling. Acceptable for klio's single-threaded model — the user
// is paying for wall time regardless of whether the program suspends
// or spins.
suspend fun delay(timeMillis: Long) {
    __kxco_delayMillis(timeMillis)
}

suspend fun yield() {
    // No-op in a single-threaded interpreter.
}

internal fun __kxco_delayMillis(millis: Long): Unit = Unit

class Channel<T> internal constructor() {
    private val items: ArrayDeque<T> = ArrayDeque()
    private var closed: Boolean = false

    suspend fun send(value: T) {
        if (closed) throw IllegalStateException("Channel is closed")
        items.addLast(value)
    }

    fun trySend(value: T): Boolean {
        if (closed) return false
        items.addLast(value)
        return true
    }

    suspend fun receive(): T {
        if (items.isEmpty()) throw IllegalStateException("Channel is empty")
        return items.removeFirst()
    }

    fun close() { closed = true }
    val isClosedForReceive: Boolean get() = closed && items.isEmpty()
    val isEmpty: Boolean get() = items.isEmpty()
}

fun <T> Channel(): Channel<T> = Channel()
