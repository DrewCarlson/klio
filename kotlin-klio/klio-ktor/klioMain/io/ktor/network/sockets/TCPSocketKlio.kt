/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copies of ktor-network's posix `TCPSocketNative.kt` and
// `TCPServerSocketNative.kt`. The connect and accept loops are upstream's; the
// `sockaddr` and `SO_ERROR` plumbing is the host natives'.

package io.ktor.network.sockets

import io.ktor.network.selector.*
import io.ktor.network.util.*
import io.ktor.utils.io.errors.*
import kotlinx.atomicfu.atomic
import kotlinx.coroutines.*
import kotlinx.io.IOException
import kotlin.coroutines.*

internal class TCPSocketNative(
    private val selector: SelectorManager,
    descriptor: Int,
    override val remoteAddress: SocketAddress,
    parent: CoroutineContext = EmptyCoroutineContext
) : NativeSocketImpl(selector, descriptor, parent), Socket {

    override val localAddress: SocketAddress
        get() = getLocalAddress(descriptor).toSocketAddress()

    internal suspend fun connect(target: NativeSocketAddress): Socket {
        val connectResult = ktor_connect(descriptor, target)

        val error = getSocketError()
        when {
            connectResult >= 0 -> {}

            isWouldBlockError(error) -> {
                while (true) {
                    selector.select(this@TCPSocketNative, SelectInterest.CONNECT)
                    val resultValue = ktor_socket_error(descriptor)
                    if (resultValue < 0) throw PosixException.forSocketError()
                    when {
                        // connected
                        resultValue == 0 -> break

                        isWouldBlockError(resultValue) -> continue

                        else -> throw PosixException.forSocketError(error = resultValue)
                    }
                }
            }

            else -> throw PosixException.forSocketError(error)
        }
        return this
    }
}

internal class TCPServerSocketNative(
    override val descriptor: Int,
    private val selector: SelectorManager,
    override val localAddress: SocketAddress,
    parent: CoroutineContext = EmptyCoroutineContext
) : SelectableBase(), ServerSocket, CoroutineScope {
    private val _socketContext: CompletableJob = SupervisorJob(parent[Job])

    override val coroutineContext: CoroutineContext = parent + Dispatchers.Unconfined + _socketContext

    override val socketContext: Job
        get() = _socketContext

    private val closeFlag = atomic(false)

    init {
        signalIgnoreSigpipe()
    }

    override suspend fun accept(): Socket {
        var clientDescriptor: Int
        while (true) {
            clientDescriptor = ktor_accept(descriptor)
            if (clientDescriptor > 0) {
                break
            }

            val error = getSocketError()
            when {
                isWouldBlockError(error) -> {
                    selector.select(this@TCPServerSocketNative, SelectInterest.ACCEPT)
                }

                else -> {
                    val posixException = PosixException.forSocketError(error)
                    throw IOException("Accept failed", posixException)
                }
            }
        }
        return buildOrCloseSocket(clientDescriptor) {
            nonBlocking(clientDescriptor).check()

            val remoteAddress = getRemoteAddress(clientDescriptor)

            TCPSocketNative(
                selector,
                clientDescriptor,
                remoteAddress = remoteAddress.toSocketAddress(),
                parent = selfContext() + coroutineContext
            )
        }
    }

    override fun close() {
        if (!closeFlag.compareAndSet(false, true)) return

        ktor_shutdown(descriptor, ShutdownCommands.Both)
        // Close select call must happen before notifyClosed, so run undispatched.
        launch(start = CoroutineStart.UNDISPATCHED) {
            // SelectorManager could throw exception if it is closed, ignore it as notifyClosed
            // will still close the descriptor as expected.
            try {
                selector.select(this@TCPServerSocketNative, SelectInterest.CLOSE)
            } catch (_: IOException) {
            }
        }
        selector.notifyClosed(this)
        _socketContext.complete()
    }
}

private suspend inline fun selfContext(): CoroutineContext = coroutineContext
