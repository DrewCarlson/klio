/*
 * Copyright 2014-2021 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's counterpart of ktor-network's posix `SocketAddressUtils.kt`: the same
// resolution, with the Unix family taken from the klio address codes.

package io.ktor.network.util

import io.ktor.network.sockets.*

internal val SocketAddress.address: NativeSocketAddress
    get() {
        val explicitAddress = resolve().firstOrNull()
        return explicitAddress ?: error("Failed to resolve address for $this")
    }

internal fun SocketAddress.resolve(): List<NativeSocketAddress> = when (this) {
    is InetSocketAddress -> getAddressInfo(hostname, port)
    is UnixSocketAddress -> listOf(NativeUnixSocketAddress(AF_UNIX.toUByte(), path))
}
