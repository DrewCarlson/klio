/*
 * Copyright 2014-2021 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copy of ktor-network's posix `CIOWriter.kt`: `ktor_send` takes the
// channel's `ByteArray` window where upstream pins it for `send`. The loop is
// upstream's. The send side is shut down in the coroutine's `finally`, as the
// reader shuts its side, where upstream does it in a completion handler: a
// job reads as completed before its handlers run, so another thread can see
// both socket jobs completed and close the descriptor first, and a descriptor
// the system has already handed to a new socket would lose its send side.

package io.ktor.network.sockets

import io.ktor.network.selector.*
import io.ktor.network.util.*
import io.ktor.utils.io.*
import io.ktor.utils.io.errors.*
import kotlinx.coroutines.*
import kotlinx.io.IOException
import kotlin.math.*

internal fun CoroutineScope.attachForWritingImpl(
    userChannel: ByteChannel,
    descriptor: Int,
    selectable: Selectable,
    selector: SelectorManager
): ReaderJob = reader(Dispatchers.IO, userChannel) {
    try {
        val source = channel
        var sockedClosed = false
        var needSelect = false
        var total = 0
        while (!sockedClosed && !source.isClosedForRead) {
            val count = source.read { memory, start, stop ->
                val remaining = stop - start
                val bytesWritten = if (remaining > 0) {
                    ktor_send(descriptor, memory, start, remaining)
                } else {
                    0
                }

                when (bytesWritten) {
                    0 -> sockedClosed = true

                    -1 -> {
                        val error = getSocketError()
                        if (isWouldBlockError(error)) {
                            needSelect = true
                        } else {
                            throw PosixException.forSocketError(error)
                        }
                    }
                }

                max(0, bytesWritten)
            }

            total += count
            if (!sockedClosed && needSelect) {
                selector.select(selectable, SelectInterest.WRITE)
                needSelect = false
            }
        }

        if (!source.isClosedForRead) {
            val availableForRead = source.availableForRead
            val cause = IOException("Failed writing to closed socket. Some bytes remaining: $availableForRead")
            source.cancel(cause)
        } else {
            source.closedCause?.let { throw it }
        }
    } finally {
        ktor_shutdown(descriptor, ShutdownCommands.Send)
    }
}
