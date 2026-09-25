/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The `Klio` engine's call: upstream's CIOApplicationCall, CIOApplicationRequest,
// CIOApplicationResponse and CIOConnectionPoint, whose connection point always
// reports `http`. Here it reports the connector's scheme, so a call on an HTTPS
// connector sees `https` (and port 443 by default) in `request.local` and
// `request.origin`, as the JVM engines report their SSL connectors. The
// response is CIO's, copied to take this call type.

package io.ktor.server.engine.klio

import io.ktor.http.*
import io.ktor.http.cio.*
import io.ktor.http.content.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.util.network.*
import io.ktor.utils.io.*
import kotlinx.coroutines.*
import kotlin.coroutines.*

internal class KlioApplicationCall(
    application: Application,
    _request: Request,
    input: ByteReadChannel,
    output: ByteWriteChannel,
    engineDispatcher: CoroutineContext,
    appDispatcher: CoroutineContext,
    upgraded: CompletableDeferred<Boolean>?,
    remoteAddress: NetworkAddress?,
    localAddress: NetworkAddress?,
    scheme: String,
    override val coroutineContext: CoroutineContext
) : BaseApplicationCall(application), CoroutineScope {

    override val request = KlioApplicationRequest(
        this,
        remoteAddress,
        localAddress,
        input,
        _request,
        scheme
    )

    override val response = KlioApplicationResponse(this, output, input, engineDispatcher, appDispatcher, upgraded)

    internal fun release() {
        request.release()
    }

    init {
        putResponseAttribute()
    }
}

internal class KlioApplicationRequest(
    call: PipelineCall,
    remoteAddress: NetworkAddress?,
    localAddress: NetworkAddress?,
    private val input: ByteReadChannel,
    private val request: Request,
    scheme: String
) : BaseApplicationRequest(call) {
    override val cookies: RequestCookies by lazy { RequestCookies(this) }

    override val engineReceiveChannel: ByteReadChannel = input

    override var engineHeaders: Headers = CIOHeaders(request.headers)

    @OptIn(InternalAPI::class)
    override val queryParameters: Parameters by lazy {
        encodeParameters(rawQueryParameters).withEmptyStringForValuelessKeys()
    }

    override val rawQueryParameters: Parameters by lazy {
        val uri = request.uri.toString()
        val queryStartIndex = uri.indexOf('?').takeIf { it != -1 } ?: return@lazy Parameters.Empty
        parseQueryString(uri, startIndex = queryStartIndex + 1, decode = false)
    }

    override val local: RequestConnectionPoint = KlioConnectionPoint(
        remoteAddress,
        localAddress,
        request.version.toString(),
        request.uri.toString(),
        request.headers[HttpHeaders.Host]?.toString(),
        HttpMethod.parse(request.method.value),
        scheme
    )

    internal fun release() {
        request.release()
    }
}

internal class KlioConnectionPoint(
    private val remoteNetworkAddress: NetworkAddress?,
    private val localNetworkAddress: NetworkAddress?,
    override val version: String,
    override val uri: String,
    private val hostHeaderValue: String?,
    override val method: HttpMethod,
    override val scheme: String
) : RequestConnectionPoint {

    private val defaultPort = URLProtocol.createOrDefault(scheme).defaultPort

    @Deprecated("Use localPort or serverPort instead")
    override val host: String
        get() = localNetworkAddress?.hostname
            ?: hostHeaderValue?.substringBefore(":")
            ?: "localhost"

    @Deprecated("Use localPort or serverPort instead")
    override val port: Int
        get() = localNetworkAddress?.port
            ?: hostHeaderValue?.substringAfter(":", defaultPort.toString())?.toInt()
            ?: defaultPort

    override val localPort: Int
        get() = localNetworkAddress?.port ?: defaultPort

    override val serverPort: Int
        get() = hostHeaderValue
            ?.substringAfterLast(":", defaultPort.toString())?.toInt()
            ?: localPort

    override val localHost: String
        get() = localNetworkAddress?.hostname ?: "localhost"

    override val serverHost: String
        get() = hostHeaderValue?.substringBeforeLast(":") ?: localHost

    override val localAddress: String
        get() = localNetworkAddress?.address ?: "localhost"

    override val remoteHost: String
        get() = remoteNetworkAddress?.hostname ?: "unknown"

    override val remotePort: Int
        get() = remoteNetworkAddress?.port ?: 0

    override val remoteAddress: String
        get() = remoteNetworkAddress?.address ?: "unknown"

    override fun toString(): String =
        "KlioConnectionPoint(uri=$uri, method=$method, version=$version, scheme=$scheme, " +
            "localAddress=$localAddress, localPort=$localPort, remoteAddress=$remoteAddress, remotePort=$remotePort)"
}

internal class KlioApplicationResponse(
    call: PipelineCall,
    private val output: ByteWriteChannel,
    private val input: ByteReadChannel,
    private val engineDispatcher: CoroutineContext,
    private val userDispatcher: CoroutineContext,
    private val upgraded: CompletableDeferred<Boolean>?
) : BaseApplicationResponse(call) {
    private var statusCode: HttpStatusCode = HttpStatusCode.OK
    private val headersBuilder = HeadersBuilder()

    private var chunkedChannel: ByteWriteChannel? = null

    private var chunkedJob: Job? = null

    override val headers = object : ResponseHeaders() {
        override fun engineAppendHeader(name: String, value: String) {
            headersBuilder.append(name, value)
        }

        override fun getEngineHeaderNames(): List<String> {
            return headersBuilder.names().toList()
        }

        override fun getEngineHeaderValues(name: String): List<String> {
            return headersBuilder.getAll(name).orEmpty()
        }
    }

    override suspend fun responseChannel(): ByteWriteChannel {
        sendResponseMessage(false)
        return preparedBodyChannel()
    }

    override suspend fun respondUpgrade(upgrade: OutgoingContent.ProtocolUpgrade) {
        sendResponseMessage(contentReady = false)

        try {
            val upgradedJob = upgrade.upgrade(input, output, engineDispatcher, userDispatcher)
            upgradedJob.join()
        } finally {
            output.flushAndClose()
            input.cancel()
        }
    }

    override suspend fun respondFromBytes(bytes: ByteArray) {
        sendResponseMessage(contentReady = true)
        val channel = preparedBodyChannel()
        return withContext(Dispatchers.Unconfined) {
            channel.writeFully(bytes)
            channel.flushAndClose()
        }
    }

    override suspend fun respondNoContent(content: OutgoingContent.NoContent) {
        sendResponseMessage(contentReady = true)
        output.flushAndClose()
    }

    override suspend fun respondOutgoingContent(content: OutgoingContent) {
        if (content is OutgoingContent.ProtocolUpgrade) {
            upgraded?.complete(true) ?: throw IllegalStateException(
                "Unable to perform upgrade as it is not requested by the client: " +
                    "request should have Upgrade and Connection headers filled properly"
            )
        } else {
            upgraded?.complete(false)
        }

        super.respondOutgoingContent(content)
        chunkedChannel?.flushAndClose()
        chunkedJob?.join()
    }

    override fun setStatus(statusCode: HttpStatusCode) {
        this.statusCode = statusCode
    }

    private suspend fun sendResponseMessage(contentReady: Boolean) {
        val builder = RequestResponseBuilder()
        try {
            builder.responseLine("HTTP/1.1", statusCode.value, statusCode.description)
            for (name in headersBuilder.names()) {
                for (value in headersBuilder.getAll(name)!!) {
                    builder.headerLine(name, value)
                }
            }
            builder.emptyLine()
            output.writePacket(builder.build())

            if (!contentReady) {
                output.flush()
            }
        } finally {
            builder.release()
        }
    }

    private fun preparedBodyChannel(): ByteWriteChannel {
        val chunked = headers[HttpHeaders.TransferEncoding] == "chunked"
        if (!chunked) return output

        val encoderJob = encodeChunked(output, Dispatchers.Unconfined)
        val chunkedOutput = encoderJob.channel

        chunkedChannel = chunkedOutput
        chunkedJob = encoderJob.job

        return chunkedOutput
    }
}
