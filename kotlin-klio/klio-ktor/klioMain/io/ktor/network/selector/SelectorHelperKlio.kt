/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's `SelectorHelper` actual, upstream's nix `SelectUtilsNix.kt` and
// `SignalPoint.kt` over the host `poll` native instead of `pselect` and
// `fd_set`s. The interest and close queues, the wakeup pipe and the selection
// loop are upstream's. `poll` reports readiness per registered event, so
// there is no FD_SETSIZE limit, and a closed descriptor comes back as
// `POLLNVAL` rather than failing the whole wait with EBADF; either way the
// events on that descriptor fail with "Bad descriptor". Like `select`, a
// pending socket error or hang-up makes the descriptor ready for its
// interest, and the operation that retries it reports the error.

package io.ktor.network.selector

import io.ktor.network.util.*
import io.ktor.util.collections.*
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import io.ktor.utils.io.errors.*
import io.ktor.utils.io.locks.*
import kotlinx.coroutines.*
import kotlinx.io.IOException
import kotlin.coroutines.*

@OptIn(InternalAPI::class)
internal actual class SelectorHelper {
    private val wakeupSignal = SignalPoint()
    private val interestQueue = LockFreeMPSCQueue<EventInfo>()
    private val closeQueue = LockFreeMPSCQueue<Int>()

    private val wakeupSignalEvent = EventInfo(
        wakeupSignal.selectionDescriptor,
        SelectInterest.READ,
        Continuation(EmptyCoroutineContext) {
        }
    )

    actual fun interest(event: EventInfo): Boolean {
        if (interestQueue.addLast(event)) {
            wakeupSignal.signal()
            return true
        }

        return false
    }

    actual fun start(scope: CoroutineScope): Job {
        return scope.launch {
            selectionLoop()
        }
    }

    actual fun requestTermination() {
        interestQueue.close()
        wakeupSignal.signal()
    }

    actual fun notifyClosed(descriptor: Int) {
        if (closeQueue.addLast(descriptor)) {
            wakeupSignal.signal()
        } else {
            closeDescriptor(descriptor)
        }
    }

    private suspend fun selectionLoop() {
        val completed = mutableSetOf<EventInfo>()
        val watchSet = mutableSetOf<EventInfo>()
        val closeSet = mutableSetOf<Int>()
        val pollSet = PollSet()

        try {
            while (!interestQueue.isClosed) {
                watchSet.add(wakeupSignalEvent)
                fillHandlersOrClose(watchSet, completed, closeSet, pollSet)

                yield()

                val ready = __kknet_poll(pollSet.fds, pollSet.events, pollSet.revents, pollSet.size, -1)
                if (ready < 0) {
                    throw PosixException.forSocketError(posixFunctionName = "poll")
                }
                if (ready == 0) continue

                processSelectedEvents(watchSet, completed, pollSet)
            }
        } finally {
            closeQueue.close()
            wakeupSignal.close()
            interestQueue.close()
            while (true) {
                val event = closeQueue.removeFirstOrNull() ?: break
                closeSet.add(event)
            }
            while (true) {
                val event = interestQueue.removeFirstOrNull() ?: break
                watchSet.add(event)
            }
            for (descriptor in closeSet) {
                closeDescriptor(descriptor)
            }
        }

        val exception = IOException("Selector closed")
        for (event in watchSet) {
            if (event.descriptor in closeSet) {
                if (event.interest == SelectInterest.CLOSE) {
                    event.complete()
                } else {
                    event.fail(IOException("Selectable closed"))
                }
            } else {
                event.fail(exception)
            }
        }
    }

    private fun fillHandlersOrClose(
        watchSet: MutableSet<EventInfo>,
        completed: MutableSet<EventInfo>,
        closeSet: MutableSet<Int>,
        pollSet: PollSet
    ) {
        pollSet.clear()

        while (true) {
            val event = closeQueue.removeFirstOrNull() ?: break
            closeSet.add(event)
        }
        while (true) {
            val event = interestQueue.removeFirstOrNull() ?: break
            watchSet.add(event)
        }

        for (descriptor in closeSet) {
            closeDescriptor(descriptor)
        }

        for (event in watchSet) {
            if (event.descriptor in closeSet) {
                if (event.interest == SelectInterest.CLOSE) {
                    event.complete()
                } else {
                    event.fail(IOException("Selectable closed"))
                }
                completed.add(event)
            } else if (event.interest != SelectInterest.CLOSE) {
                check(event.descriptor >= 0) {
                    "File descriptor ${event.descriptor} is negative"
                }
                pollSet.add(event)
            }
        }

        closeSet.clear()
        watchSet.removeAll(completed)
        completed.clear()
    }

    private fun processSelectedEvents(
        watchSet: MutableSet<EventInfo>,
        completed: MutableSet<EventInfo>,
        pollSet: PollSet
    ) {
        for (index in 0 until pollSet.size) {
            val event = pollSet.eventAt(index)
            val ready = pollSet.revents[index]
            if (ready == 0) continue

            if (ready and PollBits.NVAL != 0) {
                completed.add(event)
                event.fail(IOException("Bad descriptor ${event.descriptor} for ${event.interest}"))
                continue
            }

            if (event.descriptor == wakeupSignal.selectionDescriptor) {
                wakeupSignal.check()
                continue
            }

            val wanted = when (event.interest) {
                SelectInterest.READ, SelectInterest.ACCEPT -> PollBits.IN
                SelectInterest.WRITE, SelectInterest.CONNECT -> PollBits.OUT
                SelectInterest.CLOSE -> error("Close should not be selected")
            }
            if (ready and (wanted or PollBits.ERR or PollBits.HUP) == 0) continue

            completed.add(event)
            event.complete()
        }

        watchSet.removeAll(completed)
        completed.clear()
    }

    private fun closeDescriptor(descriptor: Int) {
        __kknet_close(descriptor)
    }
}

/** The `poll` arguments for one pass: one entry per watched event. */
private class PollSet {
    var fds: IntArray = IntArray(16)
    var events: IntArray = IntArray(16)
    var revents: IntArray = IntArray(16)
    private var watched: Array<EventInfo?> = arrayOfNulls(16)
    var size: Int = 0
        private set

    fun clear() {
        for (i in 0 until size) watched[i] = null
        size = 0
    }

    fun add(event: EventInfo) {
        if (size == fds.size) grow()
        fds[size] = event.descriptor
        events[size] = when (event.interest) {
            SelectInterest.READ, SelectInterest.ACCEPT -> PollBits.IN
            SelectInterest.WRITE, SelectInterest.CONNECT -> PollBits.OUT
            SelectInterest.CLOSE -> error("Close should not be selected")
        }
        revents[size] = 0
        watched[size] = event
        size++
    }

    fun eventAt(index: Int): EventInfo = watched[index]!!

    private fun grow() {
        val capacity = fds.size * 2
        fds = fds.copyOf(capacity)
        events = events.copyOf(capacity)
        revents = revents.copyOf(capacity)
        watched = watched.copyOf(capacity)
    }
}

/** The selector's wakeup pipe: `signal` makes its read end readable. */
@OptIn(InternalAPI::class)
internal class SignalPoint : Closeable {
    private val readDescriptor: Int
    private val writeDescriptor: Int
    private var remaining: Int = 0
    private val lock = SynchronizedObject()
    private var closed = false

    val selectionDescriptor: Int
        get() = readDescriptor

    init {
        val pipe = __kknet_pipe() ?: throw PosixException.forSocketError(posixFunctionName = "pipe")
        readDescriptor = pipe[0]
        writeDescriptor = pipe[1]
    }

    fun check() {
        synchronized(lock) {
            if (closed) return@synchronized
            while (remaining > 0) {
                remaining -= readFromPipe()
            }
        }
    }

    fun signal() {
        synchronized(lock) {
            if (closed) return@synchronized

            if (remaining > 0) return

            // A full pipe or a closed one needs no further wakeup byte.
            val result = __kknet_pipe_signal(writeDescriptor)
            if (result < 0) return

            remaining += result
        }
    }

    override fun close() {
        synchronized(lock) {
            if (closed) return@synchronized
            closed = true

            __kknet_close(writeDescriptor)
            try {
                readFromPipe()
            } catch (_: Exception) {
            }
            __kknet_close(readDescriptor)
        }
    }

    private fun readFromPipe(): Int {
        val count = __kknet_pipe_drain(readDescriptor)
        if (count < 0) throw PosixException.forSocketError(posixFunctionName = "read")
        return count
    }
}
