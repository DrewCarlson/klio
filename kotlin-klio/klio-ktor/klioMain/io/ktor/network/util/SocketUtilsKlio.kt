/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's counterpart of ktor-network's posix `SocketUtils.kt` and nix
// `SocketUtils.nix.kt`. Upstream binds these helpers to `platform.posix`
// through cinterop; here each one calls a host native from
// `src/ktor_client/net.zig`. A native returns what the POSIX call returns and
// records `errno` on failure, which `getSocketError()` reads back. Buffers are
// `ByteArray` windows and addresses travel as `NativeSocketAddress.encoded`.

@file:Suppress("FunctionName")

package io.ktor.network.util

import io.ktor.utils.io.errors.*

internal fun __kknet_socket(family: Int, type: Int): Int = -1
internal fun __kknet_errno(): Int = 0
internal fun __kknet_errno_value(name: String): Int = -1
internal fun __kknet_strerror(errno: Int): String = "Unknown error code: $errno"
internal fun __kknet_close(fd: Int): Int = -1
internal fun __kknet_shutdown(fd: Int, how: Int): Int = -1
internal fun __kknet_nonblocking(fd: Int): Int = -1
internal fun __kknet_setopt(fd: Int, option: Int, value: Int): Int = -1
internal fun __kknet_connect(fd: Int, address: ByteArray): Int = -1
internal fun __kknet_bind(fd: Int, address: ByteArray): Int = -1
internal fun __kknet_listen(fd: Int, backlog: Int): Int = -1
internal fun __kknet_accept(fd: Int): Int = -1
internal fun __kknet_so_error(fd: Int): Int = -1
internal fun __kknet_sockname(fd: Int): ByteArray? = null
internal fun __kknet_peername(fd: Int): ByteArray? = null
internal fun __kknet_getaddrinfo(host: String, port: Int): Array<ByteArray>? = null
internal fun __kknet_recv(fd: Int, buffer: ByteArray, offset: Int, length: Int): Int = -1
internal fun __kknet_send(fd: Int, buffer: ByteArray, offset: Int, length: Int): Int = -1
internal fun __kknet_recvfrom(fd: Int, buffer: ByteArray, offset: Int, length: Int): ByteArray? = null
internal fun __kknet_sendto(fd: Int, buffer: ByteArray, offset: Int, length: Int, address: ByteArray): Int = -1
internal fun __kknet_pipe(): IntArray? = null
internal fun __kknet_pipe_signal(fd: Int): Int = -1
internal fun __kknet_pipe_drain(fd: Int): Int = -1
internal fun __kknet_poll(fds: IntArray, events: IntArray, revents: IntArray, count: Int, timeoutMillis: Int): Int = -1
internal fun __kknet_fd_valid(fd: Int): Boolean = false
internal fun __kknet_ignore_sigpipe() {}
internal fun __kknet_ntop(address: ByteArray): String? = null

/** Address family codes the natives take (`AF_INET`, `AF_INET6`, `AF_UNIX`). */
internal const val AF_INET: Int = 4
internal const val AF_INET6: Int = 6
internal const val AF_UNIX: Int = 1

/** Socket type codes the natives take. */
internal const val SOCK_STREAM: Int = 1
internal const val SOCK_DGRAM: Int = 2

/** Option codes `__kknet_setopt` takes. */
internal object SocketOptionCodes {
    const val REUSE_ADDRESS: Int = 1
    const val REUSE_PORT: Int = 2
    const val BROADCAST: Int = 3
    const val RECEIVE_BUFFER: Int = 4
    const val SEND_BUFFER: Int = 5
}

/** Readiness bits `__kknet_poll` takes and reports. */
internal object PollBits {
    const val IN: Int = 1
    const val OUT: Int = 2
    const val ERR: Int = 4
    const val HUP: Int = 8
    const val NVAL: Int = 16
}

private val EAGAIN = __kknet_errno_value("EAGAIN")
private val EWOULDBLOCK = __kknet_errno_value("EWOULDBLOCK")
private val EINPROGRESS = __kknet_errno_value("EINPROGRESS")

internal fun initSocketsIfNeeded() {}

internal fun getAddressInfo(
    hostname: String,
    portInfo: Int
): List<NativeSocketAddress> {
    val entries = __kknet_getaddrinfo(hostname, portInfo)
        ?: throw PosixException.forSocketError()
    return entries.map { it.toNativeSocketAddress() }
}

internal fun getLocalAddress(descriptor: Int): NativeSocketAddress {
    val encoded = __kknet_sockname(descriptor) ?: throw PosixException.forSocketError()
    return encoded.toNativeSocketAddress()
}

internal fun getRemoteAddress(descriptor: Int): NativeSocketAddress {
    val encoded = __kknet_peername(descriptor) ?: throw PosixException.forSocketError()
    return encoded.toNativeSocketAddress()
}

internal val reusePortFlag: Int? = SocketOptionCodes.REUSE_PORT

internal object ShutdownCommands {
    val Receive: Int = 0
    val Send: Int = 1
    val Both: Int = 2
}

internal fun ktor_shutdown(fd: Int, how: Int): Int = __kknet_shutdown(fd, how)

internal fun nonBlocking(descriptor: Int): Int = __kknet_nonblocking(descriptor)

internal fun signalIgnoreSigpipe() {
    __kknet_ignore_sigpipe()
}

internal fun ktor_send(socket: Int, buffer: ByteArray, offset: Int, length: Int): Int =
    __kknet_send(socket, buffer, offset, length)

internal fun ktor_recv(socket: Int, buffer: ByteArray, offset: Int, length: Int): Int =
    __kknet_recv(socket, buffer, offset, length)

internal fun ktor_socket(family: Int, type: Int): Int = __kknet_socket(family, type)

internal fun ktor_bind(descriptor: Int, address: NativeSocketAddress): Int =
    __kknet_bind(descriptor, address.encoded)

internal fun ktor_connect(descriptor: Int, address: NativeSocketAddress): Int =
    __kknet_connect(descriptor, address.encoded)

internal fun ktor_accept(descriptor: Int): Int = __kknet_accept(descriptor)

internal fun ktor_listen(descriptor: Int, backlog: Int): Int = __kknet_listen(descriptor, backlog)

internal fun ktor_setsockopt(descriptor: Int, option: Int, value: Int): Int =
    __kknet_setopt(descriptor, option, value)

/** The pending error on a socket (`getsockopt(SOL_SOCKET, SO_ERROR)`). */
internal fun ktor_socket_error(descriptor: Int): Int = __kknet_so_error(descriptor)

internal fun PosixException.Companion.forSocketError(
    error: Int = getSocketError(),
    posixFunctionName: String? = null
): PosixException = forErrno(error, posixFunctionName)

internal fun getSocketError(): Int = __kknet_errno()

internal fun isWouldBlockError(error: Int): Boolean =
    error == EAGAIN || error == EWOULDBLOCK || error == EINPROGRESS

internal fun closeSocketDescriptor(descriptor: Int): Int = __kknet_close(descriptor)
