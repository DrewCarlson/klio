/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The test client's bridge to the test engine, with WebSockets. Upstream's
// native bridge refuses them ("Websockets for native are not supported");
// the JVM's runs the conversation over its JVM-only frame reader and writer.
// klio runs the same conversation (handleWebSocketConversation in the JVM
// source) with the client's side of the connection a RawWebSocket over the
// request and response channels, the session ktor-websockets' common and
// posix code provides.

package io.ktor.server.testing.client

import io.ktor.client.engine.*
import io.ktor.client.plugins.*
import io.ktor.client.plugins.websocket.*
import io.ktor.http.*
import io.ktor.http.content.*
import io.ktor.server.testing.*
import io.ktor.util.pipeline.*
import io.ktor.utils.io.*
import io.ktor.websocket.*
import kotlinx.coroutines.*
import kotlin.coroutines.*

internal actual class TestHttpClientEngineBridge actual constructor(
    private val engine: TestHttpClientEngine,
    private val app: TestApplicationEngine
) {

    actual val supportedCapabilities: Set<HttpClientEngineCapability<*>> =
        setOf(WebSocketCapability, HttpTimeoutCapability)

    actual suspend fun runWebSocketRequest(
        url: String,
        headers: Headers,
        content: OutgoingContent,
        callContext: CoroutineContext
    ): Pair<TestApplicationCall, WebSocketSession> =
        app.startWebSocketConversation(url, callContext) {
            with(engine) { appendRequestHeaders(headers, content) }
        }
}

/**
 * Upstream's JVM `handleWebSocketConversation` with the client session a
 * [RawWebSocket]: the server side runs the call, and once it has upgraded,
 * the session writes masked frames into the request body and reads the
 * response channel.
 */
private suspend fun TestApplicationEngine.startWebSocketConversation(
    uri: String,
    callContext: CoroutineContext,
    setup: TestApplicationRequest.() -> Unit
): Pair<TestApplicationCall, WebSocketSession> {
    val websocketChannel = ByteChannel(true)
    val call = createWebSocketCall(uri) {
        setup()
        bodyChannel = websocketChannel
    }

    // The response channel appears once the server responds.
    val responseSent: CompletableJob = Job()
    call.response.responseChannelDeferred.invokeOnCompletion { cause ->
        when (cause) {
            null -> responseSent.complete()
            else -> responseSent.completeExceptionally(cause)
        }
    }

    launch(configuration.dispatcher) {
        try {
            // execute server-side
            pipeline.execute(call)
        } catch (t: Throwable) {
            responseSent.completeExceptionally(t)
        }
    }

    return withContext(configuration.dispatcher) {
        responseSent.join()
        processResponse(call)
        val connectionEstablished = withTimeoutOrNull(1000) {
            call.response.webSocketEstablished.join()
        }
        if (connectionEstablished == null) {
            throw IllegalStateException("WebSocket connection failed")
        }
        val responseChannel = call.response.websocketChannel()
            ?: error("Expected websocket channel in the established connection")
        val session = RawWebSocket(
            responseChannel,
            websocketChannel,
            masking = true,
            coroutineContext = this@startWebSocketConversation.coroutineContext + callContext
        )
        call to session
    }
}
