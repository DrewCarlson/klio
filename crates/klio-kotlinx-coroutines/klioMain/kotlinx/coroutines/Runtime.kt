// klio platform layer for kotlinx.coroutines.
//
// The interpreter implements the core suspend / Continuation
// primitives; this layer supplies the kotlinx.coroutines runtime on
// top of them, written to klio's single-threaded cooperative model.
// `launch` posts a task onto the enclosing `runBlocking`'s scheduler
// queue, suspension points yield control back to the scheduler, and
// cancellation propagates through a host-backed token observed by
// cancellable suspending calls. The curated upstream commonMain files
// (`CompletionHandler.common.kt`, `Runnable.common.kt`) carry the
// declarative API contracts; the platform `actual`s and the builder
// runtime live here.

package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext

// Concrete empty context. kotlin.coroutines.EmptyCoroutineContext is
// a known type symbol but carries no runtime object; the builders
// only need an inert default, so this layer provides its own.
object EmptyCoroutineContext : CoroutineContext

// --- host-bound native helpers (bound by the klio host crate) -----

internal fun __kxco_delayMillis(millis: Long): Unit = Unit
internal fun __kxco_currentTimeMillis(): Long = 0L
// Cancellation tokens — opaque Long ids managed host-side. Id 0 means
// "no cancellation"; non-zero is a live token whose flag is observed
// via __kxco_tokenIsCancelled.
internal fun __kxco_tokenCreate(): Long = 0L
internal fun __kxco_tokenCancel(id: Long): Unit = Unit
internal fun __kxco_tokenIsCancelled(id: Long): Boolean = false
// Scheduler queue — host-backed FIFO of opaque task handles.
internal fun __kxco_schedulerEnqueue(handle: Long): Unit = Unit
internal fun __kxco_schedulerDrainCount(): Int = 0

// Posts a launch-block onto the enclosing runBlocking's pending queue;
// the host pumps the queue after the runBlocking body returns.
internal fun __kxco_spawn(block: () -> Unit): Unit = Unit
internal fun __kxco_scheduleResume(cont: Any): Unit = Unit

// Parallel dispatch primitives. `__kxco_dispatch` runs the block on a
// real OS-thread worker pool (Dispatchers.Default) and returns an
// opaque job id; `__kxco_dispatchIo` is the elastic IO variant;
// `__kxco_joinDispatched` blocks the caller until that job finishes
// (cross-thread happens-before).
internal fun __kxco_dispatch(block: () -> Unit): Long = 0L
internal fun __kxco_dispatchIo(block: () -> Unit): Long = 0L
internal fun __kxco_joinDispatched(id: Long): Unit = Unit

// Slot rendezvous primitives. A slot is an opaque host-side id; a
// coroutine parks indefinitely on it via __kxco_parkSlot and an
// explicit event (job completion, channel handoff) wakes it via
// __kxco_resumeSlot. Park re-checks its guard in a loop so a resume
// that races ahead of the park is harmless.
internal fun __kxco_newSlot(): Long = 0L
internal fun __kxco_parkSlot(slot: Long): Unit = Unit
internal fun __kxco_resumeSlot(slot: Long): Unit = Unit

// `runBlocking` bridges the non-suspending world into a coroutine: it
// builds a fresh scope, runs the suspend block to completion on the
// caller's stack, and drains any `launch`/resume work queued during
// the block. The platform implementation is supplied by the
// klio-kotlinx-coroutines host crate (the `actual` half); this
// `expect` carries the public signature so callers type-check.
expect fun <T> runBlocking(block: suspend CoroutineScope.() -> T): T

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
    private val slot: Long = __kxco_newSlot()
    override val tokenId: Long = __kxco_tokenCreate()
    // 0 = cooperative (park on `slot`); >0 = dispatched onto a real
    // worker — `join()` blocks the calling thread on the OS-thread
    // join instead of cooperative park.
    internal var dispatchId: Long = 0L

    override val isActive: Boolean get() = _active && !_cancelled && !__kxco_tokenIsCancelled(tokenId)
    override val isCompleted: Boolean get() = !_active
    override val isCancelled: Boolean get() = _cancelled || __kxco_tokenIsCancelled(tokenId)

    override fun cancel() {
        _cancelled = true
        _active = false
        __kxco_tokenCancel(tokenId)
        __kxco_resumeSlot(slot)
    }

    override suspend fun join() {
        if (dispatchId != 0L) {
            __kxco_joinDispatched(dispatchId)
            return
        }
        while (_active) __kxco_parkSlot(slot)
    }

    internal fun markCompleted() {
        _active = false
        __kxco_resumeSlot(slot)
    }
}

class Deferred<T> internal constructor() : Job {
    private var _done: Boolean = false
    private var _result: T? = null
    private var _cancelled: Boolean = false
    private val slot: Long = __kxco_newSlot()
    override val tokenId: Long = __kxco_tokenCreate()
    // 0 = cooperative; >0 = dispatched onto a real worker. The result
    // is written by the worker; the host publishes it on completion
    // and the OS-thread join is the happens-before that makes the
    // stored value visible here.
    internal var dispatchId: Long = 0L

    override val isActive: Boolean get() = !_done && !_cancelled
    override val isCompleted: Boolean get() = _done
    override val isCancelled: Boolean get() = _cancelled

    override fun cancel() {
        _cancelled = true
        __kxco_resumeSlot(slot)
    }

    override suspend fun join() {
        if (dispatchId != 0L) {
            __kxco_joinDispatched(dispatchId)
            return
        }
        while (!_done) __kxco_parkSlot(slot)
    }

    internal fun complete(value: T) {
        _result = value
        _done = true
        __kxco_resumeSlot(slot)
    }

    suspend fun await(): T {
        if (dispatchId != 0L) {
            __kxco_joinDispatched(dispatchId)
            return _result as T
        }
        while (!_done) __kxco_parkSlot(slot)
        return _result as T
    }
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

// A CoroutineDispatcher is itself a CoroutineContext so the builders
// accept `launch(Dispatchers.Default) { … }`. `parallelKind`
// classifies how a submitted body runs:
//   0 = cooperative single-thread (Main / Unconfined / unset) —
//       interleaved by the runBlocking interceptor at suspension
//       points.
//   1 = Default — dispatched onto the real OS-thread worker pool.
//   2 = IO — dispatched onto the elastic OS-thread pool.
abstract class CoroutineDispatcher : CoroutineContext {
    open val parallelKind: Int get() = 0
}

object Dispatchers {
    val Default: CoroutineDispatcher = object : CoroutineDispatcher() {
        override val parallelKind: Int get() = 1
    }
    val Main: CoroutineDispatcher = object : CoroutineDispatcher() {}
    val IO: CoroutineDispatcher = object : CoroutineDispatcher() {
        override val parallelKind: Int get() = 2
    }
    val Unconfined: CoroutineDispatcher = object : CoroutineDispatcher() {}
}

// Effective parallel kind of a builder `context` argument: only a
// CoroutineDispatcher carries one; every other context is
// cooperative (0).
internal fun __kxco_parallelKind(context: CoroutineContext): Int {
    return if (context is CoroutineDispatcher) context.parallelKind else 0
}

fun CoroutineScope.launch(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> Unit,
): Job {
    val job = CompletableJob()
    val scope = this
    val kind = __kxco_parallelKind(context)
    if (kind != 0) {
        val id = if (kind == 2) {
            __kxco_dispatchIo {
                if (!job.isCancelled) block(scope)
                job.markCompleted()
            }
        } else {
            __kxco_dispatch {
                if (!job.isCancelled) block(scope)
                job.markCompleted()
            }
        }
        job.dispatchId = id
        return job
    }
    __kxco_spawn {
        if (!job.isCancelled) {
            block(scope)
        }
        job.markCompleted()
    }
    return job
}

fun <T> CoroutineScope.async(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T,
): Deferred<T> {
    val deferred = Deferred<T>()
    val scope = this
    val kind = __kxco_parallelKind(context)
    if (kind != 0) {
        val id = if (kind == 2) {
            __kxco_dispatchIo {
                val r = block(scope)
                deferred.complete(r)
            }
        } else {
            __kxco_dispatch {
                val r = block(scope)
                deferred.complete(r)
            }
        }
        deferred.dispatchId = id
        return deferred
    }
    __kxco_spawn {
        val r = block(scope)
        deferred.complete(r)
    }
    return deferred
}

// `delay` / `yield` are host-bound (kotlinx.coroutines.delay /
// kotlinx.coroutines.yield) — the binding raises the cooperative
// suspension; these bodies are placeholders the overlay shadows.
suspend fun delay(timeMillis: Long) {}

suspend fun yield() {}

fun CoroutineScope.ensureActive() {
    if (!isActive) throw CancellationException("scope is no longer active")
}

// `withContext(Dispatchers.IO/Default) { … }` offloads the block onto
// a real worker thread and suspends the caller until it completes,
// returning its value. Any other context keeps the inline behavior:
// these run on the cooperative driver already (they are `suspend`
// funs invoked from inside runBlocking), so the block runs inline on
// the same driver.
suspend fun <T> withContext(context: CoroutineContext, block: suspend CoroutineScope.() -> T): T {
    val kind = __kxco_parallelKind(context)
    if (kind != 0) {
        val holder = Deferred<T>()
        val id = if (kind == 2) {
            __kxco_dispatchIo {
                val r = block(GlobalScope)
                holder.complete(r)
            }
        } else {
            __kxco_dispatch {
                val r = block(GlobalScope)
                holder.complete(r)
            }
        }
        holder.dispatchId = id
        return holder.await()
    }
    return block(GlobalScope)
}

suspend fun <T> supervisorScope(block: suspend CoroutineScope.() -> T): T {
    return block(GlobalScope)
}

suspend fun <T> coroutineScope(block: suspend CoroutineScope.() -> T): T {
    return block(GlobalScope)
}

class ClosedReceiveChannelException(message: String) : Exception(message)
class ClosedSendChannelException(message: String) : Exception(message)

interface ChannelIterator<T> {
    suspend operator fun hasNext(): Boolean
    operator fun next(): T
}

// Rendezvous (capacity 0/-1) and buffered channels. send suspends
// until a receiver takes the item (or buffer space frees); receive
// suspends until an item is available or the channel is closed and
// drained. Waiters park on slots; the counterpart resumes the oldest
// waiter. Park loops re-check their guard so a resume that races
// ahead of the park is harmless.
class Channel<T> internal constructor(private val capacity: Int = 0) {
    private val items: MutableList<T> = mutableListOf()
    private var closed: Boolean = false
    private val sendWaiters: MutableList<Long> = mutableListOf()
    private val recvWaiters: MutableList<Long> = mutableListOf()

    private fun bufferLimit(): Int = if (capacity > 0) capacity else 0

    private fun wakeOneReceiver() {
        if (recvWaiters.isNotEmpty()) __kxco_resumeSlot(recvWaiters.removeAt(0))
    }

    private fun wakeOneSender() {
        if (sendWaiters.isNotEmpty()) __kxco_resumeSlot(sendWaiters.removeAt(0))
    }

    private fun wakeAllReceivers() {
        while (recvWaiters.isNotEmpty()) __kxco_resumeSlot(recvWaiters.removeAt(0))
    }

    suspend fun send(value: T) {
        if (closed) throw ClosedSendChannelException("Channel was closed")
        while (true) {
            if (closed) throw ClosedSendChannelException("Channel was closed")
            if (recvWaiters.isNotEmpty() || items.size < bufferLimit()) {
                items.add(value)
                wakeOneReceiver()
                return
            }
            val slot = __kxco_newSlot()
            sendWaiters.add(slot)
            __kxco_parkSlot(slot)
        }
    }

    fun trySend(value: T): Boolean {
        if (closed) return false
        if (recvWaiters.isNotEmpty() || items.size < bufferLimit()) {
            items.add(value)
            wakeOneReceiver()
            return true
        }
        return false
    }

    suspend fun receive(): T {
        while (true) {
            if (items.isNotEmpty()) {
                val v = items.removeAt(0)
                wakeOneSender()
                return v
            }
            if (closed) throw ClosedReceiveChannelException("Channel was closed")
            val slot = __kxco_newSlot()
            recvWaiters.add(slot)
            __kxco_parkSlot(slot)
        }
    }

    fun tryReceive(): T? {
        if (items.isEmpty()) return null
        val v = items.removeAt(0)
        wakeOneSender()
        return v
    }

    fun close() {
        closed = true
        wakeAllReceivers()
        while (sendWaiters.isNotEmpty()) __kxco_resumeSlot(sendWaiters.removeAt(0))
    }

    internal suspend fun pull(): Boolean {
        while (true) {
            if (items.isNotEmpty()) {
                pulled = items.removeAt(0)
                hasPulled = true
                wakeOneSender()
                return true
            }
            if (closed) return false
            val slot = __kxco_newSlot()
            recvWaiters.add(slot)
            __kxco_parkSlot(slot)
        }
    }

    private var pulled: T? = null
    private var hasPulled: Boolean = false

    internal fun takePulled(): T {
        if (!hasPulled) throw NoSuchElementException("channel is closed")
        val v = pulled as T
        hasPulled = false
        pulled = null
        return v
    }

    operator fun iterator(): ChannelIterator<T> = ChannelIteratorImpl(this)

    val isClosedForReceive: Boolean get() = closed && items.isEmpty()
    val isClosedForSend: Boolean get() = closed
    val isEmpty: Boolean get() = items.isEmpty()
    val size: Int get() = items.size
}

class ChannelIteratorImpl<T> internal constructor(
    private val ch: Channel<T>,
) : ChannelIterator<T> {
    override suspend fun hasNext(): Boolean = ch.pull()
    override fun next(): T = ch.takePulled()
}

fun <T> Channel(): Channel<T> = Channel(0)
fun <T> Channel(capacity: Int): Channel<T> = Channel(capacity)
