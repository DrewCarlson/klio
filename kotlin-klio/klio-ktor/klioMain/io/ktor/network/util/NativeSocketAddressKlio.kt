/*
 * Copyright 2014-2021 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's counterpart of ktor-network's posix `NativeSocketAddress.kt` and nix
// `NativeSocketAddressNix.kt`. Upstream hands a `sockaddr` pointer to a
// callback; here an address carries its encoded bytes (`encoded`), which the
// socket natives decode into the platform `sockaddr`:
// IPv4 `[4, port_hi, port_lo, a0..a3]`, IPv6 `[6, port_hi, port_lo, addr[16],
// flowinfo, scope_id]`, Unix `[1, path...]`.

package io.ktor.network.util

import io.ktor.network.sockets.*

/**
 * Represents a native socket address.
 */
internal sealed class NativeSocketAddress(val family: UByte) {
    internal abstract val encoded: ByteArray
}

/**
 * Represents an INET socket address.
 */
internal abstract class NativeInetSocketAddress(
    family: UByte,
    val port: Int
) : NativeSocketAddress(family) {
    abstract val rawAddressBytes: ByteArray
    abstract val ipString: String
}

internal class NativeIPv4SocketAddress(
    family: UByte,
    private val address: ByteArray,
    port: Int
) : NativeInetSocketAddress(family, port) {
    override fun toString(): String = "NativeIPv4SocketAddress[$ipString:$port]"

    override val encoded: ByteArray
        get() = byteArrayOf(AF_INET.toByte(), (port shr 8).toByte(), port.toByte()) + address

    override val rawAddressBytes: ByteArray
        get() = address.copyOf()

    override val ipString: String
        get() = __kknet_ntop(address) ?: error("Failed to convert address to text")
}

internal class NativeIPv6SocketAddress(
    family: UByte,
    private val rawAddress: ByteArray,
    port: Int,
    private val flowInfo: Int,
    private val scopeId: Int
) : NativeInetSocketAddress(family, port) {

    override fun toString(): String = "NativeIPv6SocketAddress[$ipString:$port]"

    override val encoded: ByteArray
        get() = byteArrayOf(AF_INET6.toByte(), (port shr 8).toByte(), port.toByte()) +
            rawAddress + flowInfo.toBigEndianBytes() + scopeId.toBigEndianBytes()

    override val rawAddressBytes: ByteArray
        get() = rawAddress.copyOf()

    override val ipString: String
        get() = __kknet_ntop(rawAddress) ?: error("Failed to convert address to text")
}

/**
 * Represents an UNIX socket address.
 */
internal class NativeUnixSocketAddress(
    family: UByte,
    val path: String,
) : NativeSocketAddress(family) {
    override val encoded: ByteArray
        get() = byteArrayOf(AF_UNIX.toByte()) + path.encodeToByteArray()
}

internal fun NativeSocketAddress.toSocketAddress(): SocketAddress = when (this) {
    is NativeInetSocketAddress -> InetSocketAddress(ipString, port)
    is NativeUnixSocketAddress -> UnixSocketAddress(path)
}

/** Decodes an address a socket native returned. */
internal fun ByteArray.toNativeSocketAddress(): NativeSocketAddress {
    require(isNotEmpty()) { "Empty socket address" }
    val family = this[0].toInt() and 0xff
    return when (family) {
        AF_INET -> NativeIPv4SocketAddress(family.toUByte(), copyOfRange(3, 7), readPort())
        AF_INET6 -> NativeIPv6SocketAddress(
            family.toUByte(),
            copyOfRange(3, 19),
            readPort(),
            readBigEndianInt(19),
            readBigEndianInt(23)
        )
        AF_UNIX -> NativeUnixSocketAddress(family.toUByte(), copyOfRange(1, size).decodeToString())
        else -> error("Unknown address family $family")
    }
}

private fun ByteArray.readPort(): Int = ((this[1].toInt() and 0xff) shl 8) or (this[2].toInt() and 0xff)

private fun ByteArray.readBigEndianInt(offset: Int): Int =
    ((this[offset].toInt() and 0xff) shl 24) or
        ((this[offset + 1].toInt() and 0xff) shl 16) or
        ((this[offset + 2].toInt() and 0xff) shl 8) or
        (this[offset + 3].toInt() and 0xff)

private fun Int.toBigEndianBytes(): ByteArray =
    byteArrayOf((this shr 24).toByte(), (this shr 16).toByte(), (this shr 8).toByte(), toByte())
