// The dispatcher a klio window's compositions run on: the window loop's own
// thread, as a desktop window's run on the AWT event thread through skiko's
// MainUIDispatcher (Swing's, a Delay over Swing timers). Work dispatched to
// it waits for the loop, which runs it between input events and frames, and
// a delay is a timer the loop fires when it comes due. The loop waits for
// input until work or a timer is due; work dispatched or a timer set while
// it waits, from another thread, wakes it.

package androidx.compose.ui.window

import androidx.compose.ui.platform.makeSynchronizedObject
import androidx.compose.ui.platform.synchronized
import kotlin.coroutines.CoroutineContext
import kotlin.time.TimeSource
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Delay
import kotlinx.coroutines.DisposableHandle
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.Runnable

@OptIn(InternalCoroutinesApi::class, ExperimentalCoroutinesApi::class)
internal class KlioLoopDispatcher : CoroutineDispatcher(), Delay {
    private class Timer(val atNanos: Long, val order: Long, val block: Runnable) : DisposableHandle {
        var owner: KlioLoopDispatcher? = null

        override fun dispose() {
            owner?.cancel(this)
        }
    }

    private val lock = makeSynchronizedObject(this)
    private val tasks = ArrayDeque<Runnable>()
    private val timers = ArrayList<Timer>()
    private var order = 0L
    private val start = TimeSource.Monotonic.markNow()

    // Whether the loop is waiting for input (beginWait to endWait).
    private var waiting = false

    /** The loop's clock, in nanoseconds since the dispatcher was made. */
    fun nowNanos(): Long = start.elapsedNow().inWholeNanoseconds

    override fun dispatch(context: CoroutineContext, block: Runnable) {
        val wake = synchronized(lock) {
            tasks.addLast(block)
            waiting
        }
        if (wake) __composeui_appWake()
    }

    override fun scheduleResumeAfterDelay(
        timeMillis: Long,
        continuation: CancellableContinuation<Unit>,
    ) {
        val timer = schedule(timeMillis, Runnable {
            with(continuation) { this@KlioLoopDispatcher.resumeUndispatched(Unit) }
        })
        continuation.invokeOnCancellation { timer.dispose() }
    }

    override fun invokeOnTimeout(
        timeMillis: Long,
        block: Runnable,
        context: CoroutineContext,
    ): DisposableHandle = schedule(timeMillis, block)

    private fun schedule(timeMillis: Long, block: Runnable): Timer {
        // A delay too long to count in nanoseconds never comes due.
        val millis = timeMillis.coerceAtLeast(0L)
        val at = if (millis >= Long.MAX_VALUE / 2_000_000L) Long.MAX_VALUE
        else nowNanos() + millis * 1_000_000L
        var wake = false
        val timer = synchronized(lock) {
            wake = waiting
            Timer(at, order++, block).also {
                it.owner = this
                timers.add(it)
            }
        }
        // The loop's wait may end after this timer is due.
        if (wake) __composeui_appWake()
        return timer
    }

    private fun cancel(timer: Timer) {
        synchronized(lock) { timers.remove(timer) }
    }

    /** Whether work is waiting to run now. */
    val hasTasks: Boolean
        get() = synchronized(lock) { tasks.isNotEmpty() || nextDue(nowNanos()) != null }

    private fun nextDue(now: Long): Timer? {
        var due: Timer? = null
        for (t in timers) {
            if (t.atNanos <= now && (due == null || t.atNanos < due.atNanos ||
                    (t.atNanos == due.atNanos && t.order < due.order))
            ) {
                due = t
            }
        }
        return due
    }

    /**
     * Runs the queued work and the timers due, in order, until none is left,
     * work they dispatch included. True when anything ran.
     */
    fun runPending(): Boolean {
        var ran = false
        while (true) {
            val task = synchronized(lock) {
                tasks.removeFirstOrNull() ?: nextDue(nowNanos())?.let {
                    timers.remove(it)
                    it.block
                }
            } ?: break
            task.run()
            ran = true
        }
        return ran
    }

    /**
     * Runs the queued work until none is left, work it dispatches included,
     * but no timer: a FlushCoroutineDispatcher's flush. True when anything ran.
     */
    fun runQueued(): Boolean {
        var ran = false
        while (true) {
            val task = synchronized(lock) { tasks.removeFirstOrNull() } ?: break
            task.run()
            ran = true
        }
        return ran
    }

    /**
     * Marks the loop as about to wait for input, so work dispatched and timers
     * set meanwhile wake it; false, marking nothing, when work is queued.
     */
    fun beginWait(): Boolean = synchronized(lock) {
        if (tasks.isNotEmpty()) false else {
            waiting = true
            true
        }
    }

    /** The loop's wait for input is over. */
    fun endWait() {
        synchronized(lock) { waiting = false }
    }

    /** Wakes the loop if it waits for input: what it waits for changed. */
    fun wake() {
        if (synchronized(lock) { waiting }) __composeui_appWake()
    }

    /** Milliseconds until the next timer comes due, or null when none is set. */
    fun millisToNextTimer(): Long? = synchronized(lock) {
        var next = Long.MAX_VALUE
        for (t in timers) if (t.atNanos < next) next = t.atNanos
        if (next == Long.MAX_VALUE) null
        else ((next - nowNanos()) / 1_000_000L).coerceAtLeast(0L)
    }
}

/** Ends the window loop's wait for input, from any thread. */
internal fun __composeui_appWake(): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_appWake not installed")
