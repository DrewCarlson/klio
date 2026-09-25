/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copies of ktor-network's posix `DatagramSocketNative.kt` and
// `DatagramSendChannel.kt`. The channel protocol, locking and pooling are
// upstream's; `sendto` and `recvfrom` are the host natives, which take the
// datagram's `ByteArray` window where upstream pins it.

package io.ktor.network.sockets

import io.ktor.network.selector.*
import io.ktor.network.util.*
import io.ktor.utils.io.core.*
import io.ktor.utils.io.errors.*
import io.ktor.utils.io.pool.*
import kotlinx.atomicfu.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.selects.*
import kotlinx.coroutines.sync.*
import kotlinx.io.*
import kotlinx.io.IOException
import kotlinx.io.unsafe.*
import kotlin.coroutines.*

internal class DatagramSocketNative(
    val selector: SelectorManager,
    descriptor: Int,
    private val remote: SocketAddress?,
    parent: CoroutineContext = EmptyCoroutineContext
) : BoundDatagramSocket, ConnectedDatagramSocket, NativeSocketImpl(
    selector,
    descriptor,
    parent
) {
    override val localAddress: SocketAddress
        get() = getLocalAddress(descriptor).toSocketAddress()

    override val remoteAddress: SocketAddress
        get() = getRemoteAddress(descriptor).toSocketAddress()

    private val sender: SendChannel<Datagram> = DatagramSendChannel(descriptor, this, remote)

    override fun toString(): String = "DatagramSocketNative(descriptor=$descriptor)"

    @OptIn(ExperimentalCoroutinesApi::class)
    private val receiver: ReceiveChannel<Datagram> = produce(Dispatchers.IO) {
        try {
            while (true) {
                val received = readDatagram()
                channel.send(received)
            }
        } catch (_: ClosedSendChannelException) {
        } catch (cause: IOException) {
        } catch (cause: PosixException) {
        }
    }

    override val incoming: ReceiveChannel<Datagram>
        get() = receiver

    override val outgoing: SendChannel<Datagram>
        get() = sender

    override fun close() {
        receiver.cancel()
        super.close()
        sender.close()
    }

    private suspend fun readDatagram(): Datagram {
        while (true) {
            val datagram = tryReadDatagram()
            if (datagram != null) return datagram
            selector.select(this, SelectInterest.READ)
        }
    }

    private fun tryReadDatagram(): Datagram? {
        return DefaultDatagramByteArrayPool.useInstance { buffer ->
            val received = __kknet_recvfrom(descriptor, buffer, 0, buffer.size)
            if (received == null) {
                val error = getSocketError()
                if (isWouldBlockError(error)) return null
                if (error == 0) return null
                throw PosixException.forSocketError(error)
            }
            val countOffset = received.size - 4
            val bytesRead = ((received[countOffset].toInt() and 0xff) shl 24) or
                ((received[countOffset + 1].toInt() and 0xff) shl 16) or
                ((received[countOffset + 2].toInt() and 0xff) shl 8) or
                (received[countOffset + 3].toInt() and 0xff)

            if (bytesRead == 0) throw IOException("Failed reading from closed socket")

            val address = received.copyOfRange(0, countOffset).toNativeSocketAddress()

            Datagram(
                buildPacket { writeFully(buffer, length = bytesRead) },
                address.toSocketAddress()
            )
        }
    }
}

private val CLOSED: (Throwable?) -> Unit = {}
private val CLOSED_INVOKED: (Throwable?) -> Unit = {}

internal class DatagramSendChannel(
    val descriptor: Int,
    val socket: DatagramSocketNative,
    val remote: SocketAddress?
) : SendChannel<Datagram> {
    private val onCloseHandler = atomic<((Throwable?) -> Unit)?>(null)
    private val closed = atomic(false)
    private val closedCause = atomic<Throwable?>(null)
    private val lock = Mutex()

    @DelicateCoroutinesApi
    override val isClosedForSend: Boolean
        get() = closed.value

    override fun close(cause: Throwable?): Boolean {
        if (!closed.compareAndSet(false, true)) {
            return false
        }

        closedCause.value = cause

        if (!socket.isClosed) {
            socket.close()
        }

        closeAndCheckHandler()

        return true
    }

    @OptIn(InternalCoroutinesApi::class, InternalIoApi::class, UnsafeIoApi::class)
    override fun trySend(element: Datagram): ChannelResult<Unit> {
        if (!lock.tryLock()) return ChannelResult.failure()
        if (remote != null) {
            check(element.address == remote) {
                "Datagram address ${element.address} doesn't match the connected address $remote"
            }
        }

        try {
            val packetSize = element.packet.remaining
            var writeWithPool = false
            UnsafeBufferOperations.readFromHead(element.packet.buffer) { bytes, startIndex, endIndex ->
                val length = endIndex - startIndex
                if (length < packetSize) {
                    // Packet is too large to read directly.
                    writeWithPool = true
                    return@readFromHead 0
                }

                val bytesWritten = sendto(element, bytes, startIndex, length)

                when (bytesWritten) {
                    0 -> throw IOException("Failed writing to closed socket")

                    -1 -> {
                        val error = getSocketError()
                        if (isWouldBlockError(error)) {
                            0
                        } else {
                            throw PosixException.forSocketError(error)
                        }
                    }

                    else -> length
                }
            }
            if (writeWithPool) {
                DefaultDatagramByteArrayPool.useInstance { buffer ->
                    val length = element.packet.remaining.toInt()
                    element.packet.peek().readTo(buffer, endIndex = length)

                    val bytesWritten = sendto(element, buffer, 0, length)

                    when (bytesWritten) {
                        0 -> throw IOException("Failed writing to closed socket")

                        -1 -> {
                            val error = getSocketError()
                            if (isWouldBlockError(error)) {
                            } else {
                                throw PosixException.forSocketError(error)
                            }
                        }

                        else -> {
                            element.packet.discard()
                        }
                    }
                }
            }
        } finally {
            lock.unlock()
        }

        return ChannelResult.success(Unit)
    }

    @OptIn(InternalIoApi::class, UnsafeIoApi::class)
    override suspend fun send(element: Datagram) {
        if (remote != null) {
            check(element.address == remote) {
                "Datagram address ${element.address} doesn't match the connected address $remote"
            }
        }

        lock.withLock {
            withContext(Dispatchers.IO) {
                val packetSize = element.packet.remaining
                var writeWithPool = false
                UnsafeBufferOperations.readFromHead(element.packet.buffer) { bytes, startIndex, endIndex ->
                    val length = endIndex - startIndex
                    if (length < packetSize) {
                        // Packet is too large to read directly.
                        writeWithPool = true
                        return@readFromHead 0
                    }
                    sendSuspend(element, bytes, startIndex, length)
                    length
                }
                if (writeWithPool) {
                    DefaultDatagramByteArrayPool.useInstance { buffer ->
                        val length = element.packet.remaining.toInt()
                        element.packet.readTo(buffer, endIndex = length)

                        sendSuspend(element, buffer, 0, length)
                    }
                }
            }
        }
    }

    private fun sendto(datagram: Datagram, buffer: ByteArray, offset: Int, length: Int): Int {
        return if (remote == null) {
            __kknet_sendto(descriptor, buffer, offset, length, datagram.address.address.encoded)
        } else {
            __kknet_send(descriptor, buffer, offset, length)
        }
    }

    private tailrec suspend fun sendSuspend(
        datagram: Datagram,
        buffer: ByteArray,
        offset: Int,
        length: Int
    ) {
        val bytesWritten: Int = sendto(datagram, buffer, offset, length)

        when (bytesWritten) {
            0 -> throw IOException("Failed writing to closed socket")

            -1 -> {
                val error = getSocketError()
                if (isWouldBlockError(error)) {
                    socket.selector.select(socket, SelectInterest.WRITE)
                    sendSuspend(datagram, buffer, offset, length)
                } else {
                    throw PosixException.forSocketError(error)
                }
            }
        }
    }

    override val onSend: SelectClause2<Datagram, SendChannel<Datagram>>
        get() = TODO("[DatagramSendChannel] doesn't support [onSend] select clause")

    @ExperimentalCoroutinesApi
    override fun invokeOnClose(handler: (cause: Throwable?) -> Unit) {
        if (onCloseHandler.compareAndSet(null, handler)) {
            return
        }

        if (onCloseHandler.value === CLOSED) {
            require(onCloseHandler.compareAndSet(CLOSED, CLOSED_INVOKED))
            handler(closedCause.value)
            return
        }

        failInvokeOnClose(onCloseHandler.value)
    }

    private fun closeAndCheckHandler() {
        while (true) {
            val handler = onCloseHandler.value
            if (handler === CLOSED_INVOKED) break
            if (handler == null) {
                if (onCloseHandler.compareAndSet(null, CLOSED)) break
                continue
            }

            require(onCloseHandler.compareAndSet(handler, CLOSED_INVOKED))
            handler(closedCause.value)
            break
        }
    }
}

private fun failInvokeOnClose(handler: ((cause: Throwable?) -> Unit)?) {
    val message = if (handler === CLOSED_INVOKED) {
        "Another handler was already registered and successfully invoked"
    } else {
        "Another handler was already registered: $handler"
    }

    throw IllegalStateException(message)
}
