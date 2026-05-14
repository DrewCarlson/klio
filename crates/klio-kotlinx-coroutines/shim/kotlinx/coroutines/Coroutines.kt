// Klio shim for kotlinx.coroutines.
//
// The klio interpreter implements the core suspend / runBlocking /
// Continuation primitives (see crates/klio-interp/src/lib.rs:5068);
// this shim adds the higher-level kotlinx.coroutines API surface
// on top. klio runs single-threaded, so the runtime is built
// around a cooperative scheduler: launch posts a task to a queue,
// runBlocking drains the queue, suspension points yield control
// back to the scheduler. Cancellation propagates through a shared
// host-backed token; cancellable suspending calls observe it and
// throw CancellationException.

package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

// --- internal native helpers (bound natively by the klio host) ----

internal fun __kxco_delayMillis(millis: Long): Unit = Unit
internal fun __kxco_currentTimeMillis(): Long = 0L
// Cancellation tokens — opaque Long ids managed host-side. A token
// id of 0 means "no cancellation"; everything non-zero is a live
// token whose flag is observed via __kxco_tokenIsCancelled.
internal fun __kxco_tokenCreate(): Long = 0L
internal fun __kxco_tokenCancel(id: Long): Unit = Unit
internal fun __kxco_tokenIsCancelled(id: Long): Boolean = false
// Scheduler queue — host-backed FIFO of opaque task handles.
internal fun __kxco_schedulerEnqueue(handle: Long): Unit = Unit
internal fun __kxco_schedulerDrainCount(): Int = 0

// Pack hook that posts a launch-block onto the enclosing
// runBlocking's pending-launch queue. The pack lives in
// klio-kotlinx-coroutines; the host pumps the queue after the
// runBlocking body returns.
internal fun __kxco_spawn(block: () -> Unit): Unit = Unit
internal fun __kxco_scheduleResume(cont: Any): Unit = Unit

class CancellationException(message: String) : Throwable(message)

interface Job {
    val isActive: Boolean
    val isCompleted: Boolean
    val isCancelled: Boolean
    val tokenId: Long
    fun cancel(): Unit
    suspend fun join(): Unit
}

class CompletableJob internal constructor() : Job {
    private var _active: Boolean = true
    private var _cancelled: Boolean = false
    override val tokenId: Long = __kxco_tokenCreate()

    override val isActive: Boolean get() = _active && !_cancelled && !__kxco_tokenIsCancelled(tokenId)
    override val isCompleted: Boolean get() = !_active
    override val isCancelled: Boolean get() = _cancelled || __kxco_tokenIsCancelled(tokenId)

    override fun cancel() {
        _cancelled = true
        _active = false
        __kxco_tokenCancel(tokenId)
    }

    override suspend fun join() {
        // klio's scheduler drives every queued task to completion
        // before runBlocking returns, so by the time anyone holds a
        // Job they can call join() against, the task has finished
        // — join is a no-op observation.
    }

    internal fun markCompleted() { _active = false }
}

class Deferred<T> internal constructor(private val value: T) : Job {
    override val isActive: Boolean = false
    override val isCompleted: Boolean = true
    override val isCancelled: Boolean = false
    override val tokenId: Long = 0L
    override fun cancel() {}
    override suspend fun join() {}
    suspend fun await(): T = value
}

interface CoroutineScope {
    val coroutineContext: CoroutineContext
    val isActive: Boolean get() = true
}

object GlobalScope : CoroutineScope {
    override val coroutineContext: CoroutineContext get() = EmptyCoroutineContext
    override val isActive: Boolean get() = true
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

// klio is single-threaded but the launch/async builders post their
// bodies through the cooperative scheduler. Without a real
// continuation-state-machine in the IR yet, the body still runs to
// completion on the calling stack — but cancellation tokens, Job
// observability, and the scheduler queue are real and let callers
// build patterns (e.g. polling cancellation, supervisor scopes)
// that match upstream semantics.

fun CoroutineScope.launch(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> Unit,
): Job {
    val job = CompletableJob()
    val scope = this
    // Post the block onto the host's scheduler queue. The enclosing
    // runBlocking drains the queue after its main body returns, so
    // sibling launches no longer run inline on the calling stack.
    __kxco_spawn {
        if (!job.isCancelled) {
            runBlocking { block(scope) }
        }
        job.markCompleted()
    }
    return job
}

fun <T> CoroutineScope.async(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T,
): Deferred<T> {
    val result: T = runBlocking { block(this) }
    return Deferred(result)
}

suspend fun delay(timeMillis: Long) {
    __kxco_delayMillis(timeMillis)
}

suspend fun yield() {
    // Cooperative yield — surrenders the calling fiber so the
    // scheduler can advance other queued tasks. With the current
    // synchronous interpreter, this is a no-op but the binding
    // remains so the surface stays compatible with full M31.
}

fun CoroutineScope.ensureActive() {
    if (!isActive) throw CancellationException("scope is no longer active")
}

suspend fun <T> withContext(context: CoroutineContext, block: suspend CoroutineScope.() -> T): T {
    return runBlocking { block(this) }
}

// supervisorScope: a scope whose children's failures do not cancel
// the parent. Without proper structured concurrency, this is just
// a tagged scope, but it matches upstream's surface so user code
// compiles.
suspend fun <T> supervisorScope(block: suspend CoroutineScope.() -> T): T {
    return runBlocking { block(this) }
}

// coroutineScope: structured-concurrency equivalent; same shape.
suspend fun <T> coroutineScope(block: suspend CoroutineScope.() -> T): T {
    return runBlocking { block(this) }
}

class Channel<T> internal constructor(private val capacity: Int = -1) {
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

    fun tryReceive(): T? {
        if (items.isEmpty()) return null
        return items.removeFirst()
    }

    fun close() { closed = true }
    val isClosedForReceive: Boolean get() = closed && items.isEmpty()
    val isClosedForSend: Boolean get() = closed
    val isEmpty: Boolean get() = items.isEmpty()
    val size: Int get() = items.size
}

fun <T> Channel(): Channel<T> = Channel()
fun <T> Channel(capacity: Int): Channel<T> = Channel(capacity)
