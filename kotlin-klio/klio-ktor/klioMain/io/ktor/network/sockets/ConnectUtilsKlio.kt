/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copies of ktor-network's posix `ConnectUtilsNative.kt`,
// `UDPSocketBuilderNative.kt` and `NativeSocketOptions.kt`: the same socket
// setup order, over the host natives.

package io.ktor.network.sockets

import io.ktor.network.selector.*
import io.ktor.network.util.*
import io.ktor.utils.io.errors.*
import kotlinx.io.IOException

private const val DEFAULT_BACKLOG_SIZE = 50

internal actual suspend fun tcpConnect(
    selector: SelectorManager,
    remoteAddress: SocketAddress,
    socketOptions: SocketOptions.TCPClientSocketOptions
): Socket {
    initSocketsIfNeeded()

    var lastException: PosixException? = null
    for (remote in remoteAddress.resolve()) {
        try {
            val descriptor: Int = ktor_socket(remote.family.toInt(), SOCK_STREAM).check()

            val socket = buildOrCloseSocket(descriptor) {
                assignOptions(descriptor, socketOptions)
                nonBlocking(descriptor).check()

                TCPSocketNative(
                    selector,
                    descriptor,
                    remoteAddress = remote.toSocketAddress()
                )
            }

            try {
                return socket.connect(remote)
            } catch (throwable: Throwable) {
                socket.close()
                throw throwable
            }
        } catch (exception: PosixException) {
            lastException = exception
        }
    }

    throw IOException("Failed to connect to $remoteAddress.", lastException)
}

internal actual suspend fun tcpBind(
    selector: SelectorManager,
    localAddress: SocketAddress?,
    socketOptions: SocketOptions.AcceptorOptions
): ServerSocket {
    initSocketsIfNeeded()

    val address = localAddress?.address ?: getAnyLocalAddress()
    val descriptor = ktor_socket(address.family.toInt(), SOCK_STREAM).check()

    buildOrCloseSocket(descriptor) {
        assignOptions(descriptor, socketOptions)
        nonBlocking(descriptor).check()

        ktor_bind(descriptor, address).check()

        ktor_listen(descriptor, DEFAULT_BACKLOG_SIZE).check()

        val resolvedLocalAddress = getLocalAddress(descriptor)

        return TCPServerSocketNative(
            descriptor,
            selector,
            localAddress = resolvedLocalAddress.toSocketAddress(),
            parent = selector.coroutineContext
        )
    }
}

internal actual suspend fun udpConnect(
    selector: SelectorManager,
    remoteAddress: SocketAddress,
    localAddress: SocketAddress?,
    options: SocketOptions.UDPSocketOptions
): ConnectedDatagramSocket {
    initSocketsIfNeeded()

    val address = localAddress?.address ?: getAnyLocalAddress()

    val descriptor = ktor_socket(address.family.toInt(), SOCK_DGRAM).check()

    buildOrCloseSocket(descriptor) {
        assignOptions(descriptor, options)
        nonBlocking(descriptor)

        ktor_bind(descriptor, address).check()

        ktor_connect(descriptor, remoteAddress.address).check()

        return DatagramSocketNative(
            selector = selector,
            descriptor = descriptor,
            remote = remoteAddress,
            parent = selector.coroutineContext
        )
    }
}

internal actual suspend fun udpBind(
    selector: SelectorManager,
    localAddress: SocketAddress?,
    options: SocketOptions.UDPSocketOptions
): BoundDatagramSocket {
    initSocketsIfNeeded()

    val address = localAddress?.address ?: getAnyLocalAddress()

    val descriptor = ktor_socket(address.family.toInt(), SOCK_DGRAM).check()

    buildOrCloseSocket(descriptor) {
        assignOptions(descriptor, options)
        nonBlocking(descriptor)

        ktor_bind(descriptor, address).check()

        return DatagramSocketNative(
            selector = selector,
            descriptor = descriptor,
            remote = null,
            parent = selector.coroutineContext
        )
    }
}

internal fun assignOptions(descriptor: Int, options: SocketOptions) {
    setSocketFlag(descriptor, SocketOptionCodes.REUSE_ADDRESS, options.reuseAddress)
    reusePortFlag?.let { setSocketFlag(descriptor, it, options.reusePort) }
    if (options is SocketOptions.UDPSocketOptions) {
        setSocketFlag(descriptor, SocketOptionCodes.BROADCAST, options.broadcast)
    }

    if (options is SocketOptions.UDPSocketOptions) {
        options.receiveBufferSize.takeIf { it > 0 }?.let {
            setSocketOption(descriptor, SocketOptionCodes.RECEIVE_BUFFER, it)
        }
        options.sendBufferSize.takeIf { it > 0 }?.let {
            setSocketOption(descriptor, SocketOptionCodes.SEND_BUFFER, it)
        }
    }
}

private fun setSocketFlag(
    descriptor: Int,
    optionName: Int,
    optionValue: Boolean
) = setSocketOption(descriptor, optionName, if (optionValue) 1 else 0)

private fun setSocketOption(
    descriptor: Int,
    optionName: Int,
    optionValue: Int
) {
    ktor_setsockopt(descriptor, optionName, optionValue).check()
}
