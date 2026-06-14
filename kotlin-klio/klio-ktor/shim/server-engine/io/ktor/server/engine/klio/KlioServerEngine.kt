// klio's `ApplicationEngine` for the real upstream ktor-server-core (the
// "custom actual" the architecture calls for, the server counterpart to
// `KlioClientEngine`). It is a thin bridge over the native Zig transport:
// `__kktor_serve` (host binding) owns the socket bind/accept and HTTP I/O and
// hands each request to `dispatch` as flat strings; this engine builds a real
// ktor `ApplicationCall` from them, runs it through the upstream engine
// pipeline (routing + plugins), and returns the captured response strings.

package io.ktor.server.engine.klio

import io.ktor.events.Events
import io.ktor.http.Headers
import io.ktor.http.HeadersBuilder
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.Parameters
import io.ktor.http.RequestConnectionPoint
import io.ktor.http.content.OutgoingContent
import io.ktor.http.encodeParameters
import io.ktor.http.parseQueryString
import io.ktor.http.withEmptyStringForValuelessKeys
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.ApplicationEnvironment
import io.ktor.server.application.PipelineCall
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.ApplicationEngineFactory
import io.ktor.server.engine.BaseApplicationCall
import io.ktor.server.engine.BaseApplicationEngine
import io.ktor.server.engine.BaseApplicationRequest
import io.ktor.server.engine.BaseApplicationResponse
import io.ktor.server.engine.__kktor_serve
import io.ktor.server.request.RequestCookies
import io.ktor.server.response.ResponseHeaders
import io.ktor.util.InternalAPI
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.coroutines.CoroutineContext

/**
 * Engine factory: `embeddedServer(Klio, port) { … }`.
 */
public object Klio : ApplicationEngineFactory<KlioServerEngine, KlioServerEngine.Configuration> {
    override fun configuration(
        configure: KlioServerEngine.Configuration.() -> Unit
    ): KlioServerEngine.Configuration = KlioServerEngine.Configuration().apply(configure)

    override fun create(
        environment: ApplicationEnvironment,
        monitor: Events,
        developmentMode: Boolean,
        configuration: KlioServerEngine.Configuration,
        applicationProvider: () -> Application
    ): KlioServerEngine =
        KlioServerEngine(environment, monitor, developmentMode, configuration, applicationProvider)
}

public class KlioServerEngine(
    environment: ApplicationEnvironment,
    monitor: Events,
    developmentMode: Boolean,
    public val configuration: Configuration,
    private val applicationProvider: () -> Application,
) : BaseApplicationEngine(environment, monitor, developmentMode) {

    public class Configuration : ApplicationEngine.Configuration()

    override fun start(wait: Boolean): ApplicationEngine {
        val port = configuration.connectors.firstOrNull()?.port ?: 80
        resolvedConnectorsDeferred.complete(configuration.connectors)
        if (wait) {
            __kktor_serve(port) { req -> handle(req) }
        } else {
            // `start(wait = false)` returns immediately and serves on a
            // dispatcher-pool worker (a daemon task the run boundary can
            // abandon), so the accept loop's run-boundary poll lets the
            // process exit instead of blocking here.
            GlobalScope.launch(Dispatchers.Default) {
                yield()
                __kktor_serve(port) { req -> handle(req) }
            }
        }
        return this
    }

    override suspend fun startSuspend(wait: Boolean): ApplicationEngine = start(wait)

    override fun stop(gracePeriodMillis: Long, timeoutMillis: Long) {}

    override suspend fun stopSuspend(gracePeriodMillis: Long, timeoutMillis: Long) {}

    // One request: native strings -> real call -> upstream pipeline -> strings.
    private fun handle(req: Array<String>): Array<String> {
        val method = req[0]
        val rawTarget = req[1]
        val body = req[2]
        val headers = HeadersBuilder()
        var i = 3
        while (i + 1 < req.size) {
            headers.append(req[i], req[i + 1])
            i += 2
        }

        val call = KlioApplicationCall(applicationProvider(), method, rawTarget, headers.build(), body)
        runBlocking { pipeline.execute(call) }

        val response = call.response
        val out = ArrayList<String>()
        out.add(response.statusCode.value.toString())
        out.add(response.contentTypeValue())
        out.add(response.bodyText())
        for (name in response.headerNames()) {
            if (name.equals(HttpHeaders.ContentType, ignoreCase = true) ||
                name.equals(HttpHeaders.ContentLength, ignoreCase = true)
            ) {
                continue
            }
            for (value in response.headerValues(name)) {
                out.add(name)
                out.add(value)
            }
        }
        return out.toTypedArray()
    }
}

internal class KlioApplicationCall(
    application: Application,
    method: String,
    rawTarget: String,
    requestHeaders: Headers,
    bodyText: String,
) : BaseApplicationCall(application) {
    override val coroutineContext: CoroutineContext = application.coroutineContext
    override val request: KlioApplicationRequest =
        KlioApplicationRequest(this, method, rawTarget, requestHeaders, bodyText)
    override val response: KlioApplicationResponse = KlioApplicationResponse(this)

    init {
        putResponseAttribute()
    }
}

internal class KlioApplicationRequest(
    call: PipelineCall,
    method: String,
    private val rawTarget: String,
    requestHeaders: Headers,
    bodyText: String,
) : BaseApplicationRequest(call) {
    override val engineHeaders: Headers = requestHeaders
    override val engineReceiveChannel: ByteReadChannel = ByteReadChannel(bodyText.encodeToByteArray())
    override val cookies: RequestCookies by lazy { RequestCookies(this) }

    override val rawQueryParameters: Parameters by lazy {
        val q = rawTarget.indexOf('?')
        if (q < 0) Parameters.Empty else parseQueryString(rawTarget, startIndex = q + 1, decode = false)
    }

    @OptIn(InternalAPI::class)
    override val queryParameters: Parameters by lazy {
        encodeParameters(rawQueryParameters)
    }

    override val local: RequestConnectionPoint =
        KlioConnectionPoint(method, rawTarget, requestHeaders[HttpHeaders.Host])
}

internal class KlioApplicationResponse(
    call: PipelineCall,
) : BaseApplicationResponse(call) {
    private var statusCode: HttpStatusCode = HttpStatusCode.OK
    private val headersBuilder = HeadersBuilder()
    private var bodyBytes: ByteArray = ByteArray(0)

    override val headers: ResponseHeaders = object : ResponseHeaders() {
        override fun engineAppendHeader(name: String, value: String) {
            headersBuilder.append(name, value)
        }

        override fun getEngineHeaderNames(): List<String> = headersBuilder.names().toList()

        override fun getEngineHeaderValues(name: String): List<String> =
            headersBuilder.getAll(name).orEmpty()
    }

    override fun setStatus(statusCode: HttpStatusCode) {
        this.statusCode = statusCode
    }

    override suspend fun respondFromBytes(bytes: ByteArray) {
        bodyBytes = bytes
    }

    override suspend fun respondNoContent(content: OutgoingContent.NoContent) {
        bodyBytes = ByteArray(0)
    }

    override suspend fun responseChannel(): ByteWriteChannel {
        val channel = io.ktor.utils.io.ByteChannel(autoFlush = true)
        return channel
    }

    override suspend fun respondUpgrade(upgrade: OutgoingContent.ProtocolUpgrade) {
        throw UnsupportedOperationException("Protocol upgrade is not supported by the klio server engine")
    }

    internal fun contentTypeValue(): String =
        headersBuilder[HttpHeaders.ContentType] ?: "text/plain"

    internal fun bodyText(): String = bodyBytes.decodeToString()

    internal fun headerNames(): List<String> = headersBuilder.names().toList()

    internal fun headerValues(name: String): List<String> = headersBuilder.getAll(name).orEmpty()
}

internal class KlioConnectionPoint(
    method: String,
    override val uri: String,
    private val hostHeader: String?,
) : RequestConnectionPoint {
    override val scheme: String = "http"
    override val version: String = "HTTP/1.1"
    override val method: HttpMethod = HttpMethod.parse(method)

    override val localHost: String get() = hostHeader?.substringBefore(":") ?: "localhost"
    override val serverHost: String get() = localHost
    override val localAddress: String get() = "127.0.0.1"
    override val localPort: Int get() = hostHeader?.substringAfter(":", "80")?.toIntOrNull() ?: 80
    override val serverPort: Int get() = localPort
    override val remoteHost: String get() = "unknown"
    override val remoteAddress: String get() = "unknown"
    override val remotePort: Int get() = 0

    @Deprecated("Use localHost or serverHost instead")
    override val host: String get() = localHost

    @Deprecated("Use localPort or serverPort instead")
    override val port: Int get() = localPort
}
