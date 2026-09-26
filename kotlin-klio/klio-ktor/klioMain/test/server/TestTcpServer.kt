/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's copy of ktor-test-server's TestTcpServer.kt: the selector is the
// platform `SelectorManager` instead of the JVM's ActorSelectorManager, and
// the port is bound with address reuse, as the HTTP servers are, so a census
// can start the servers again right after stopping them.

package test.server

import io.ktor.network.selector.*
import io.ktor.network.sockets.*
import kotlinx.coroutines.*

internal class TestTcpServer(
    val port: Int,
    scope: CoroutineScope,
    private val handler: suspend (Socket) -> Unit,
) {
    private val selector = SelectorManager(Dispatchers.IO)

    private val serverSocket = runBlocking { aSocket(selector).tcp().bind(port = port) { reuseAddress = true } }

    init {
        scope.launch {
            serverSocket.use { it.serve() }
        }.invokeOnCompletion {
            selector.close()
        }
    }

    private suspend fun ServerSocket.serve() = coroutineScope {
        while (isActive) {
            val socket = try {
                accept()
            } catch (cause: Throwable) {
                if (cause is CancellationException) throw cause
                println("Test server failed to accept: $cause")
                cause.printStackTrace()
                continue
            }

            launch {
                try {
                    socket.use { handler(it) }
                } catch (cause: Throwable) {
                    if (cause is CancellationException) throw cause
                    println("Exception in tcp server: $cause")
                    cause.printStackTrace()
                }
            }
        }
    }
}
