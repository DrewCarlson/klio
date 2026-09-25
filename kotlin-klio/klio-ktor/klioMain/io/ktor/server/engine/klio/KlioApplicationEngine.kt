/*
* Copyright 2014-2021 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
*/

// The engine behind `Klio`: upstream's CIOApplicationEngine with HTTPS. Plain
// connectors run CIO's `httpServer` as CIO does; an HTTPS connector
// (`sslConnector`) runs the same accept loop and request pipeline over each
// connection's TLS session, from klio's TLS 1.3 engine, and its calls report
// the `https` scheme.

package io.ktor.server.engine.klio

import io.ktor.events.*
import io.ktor.http.*
import io.ktor.http.cio.Request
import io.ktor.network.selector.*
import io.ktor.network.sockets.*
import io.ktor.network.tls.*
import io.ktor.server.application.*
import io.ktor.server.cio.*
import io.ktor.server.cio.backend.*
import io.ktor.server.cio.internal.*
import io.ktor.server.engine.*
import io.ktor.server.engine.internal.ClosedChannelException
import io.ktor.server.http.HttpRequestCloseHandlerKey
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.util.logging.*
import io.ktor.util.pipeline.*
import io.ktor.utils.io.*
import kotlinx.coroutines.*
import kotlinx.io.IOException
import kotlin.concurrent.Volatile
import kotlin.time.Duration.Companion.seconds

private val LOGGER = KtorSimpleLogger("io.ktor.server.engine.klio.KlioApplicationEngine")

/**
 * The CIO engine with HTTPS connectors.
 */
public class KlioApplicationEngine(
    environment: ApplicationEnvironment,
    monitor: Events,
    developmentMode: Boolean,
    public val configuration: CIOApplicationEngine.Configuration,
    private val applicationProvider: () -> Application
) : BaseApplicationEngine(environment, monitor, developmentMode) {

    private val engineDispatcher = Dispatchers.IOBridge

    private val userDispatcher = Dispatchers.IOBridge

    private val startupJob: CompletableDeferred<Unit> = CompletableDeferred()
    private val stopRequest: CompletableJob = Job()

    // See KT-67440
    @Volatile
    private var serverJob: Job = Job()

    init {
        serverJob = initServerJob()
        serverJob.invokeOnCompletion { cause ->
            cause?.let { stopRequest.completeExceptionally(cause) }
            cause?.let { startupJob.completeExceptionally(cause) }
        }
    }

    override suspend fun startSuspend(wait: Boolean): ApplicationEngine {
        serverJob.start()

        startupJob.await()
        monitor.raiseCatching(ServerReady, environment, environment.log)

        if (wait) {
            serverJob.join()
        }

        return this
    }

    override fun start(wait: Boolean): ApplicationEngine = runBlockingBridge { startSuspend(wait) }

    override suspend fun stopSuspend(gracePeriodMillis: Long, timeoutMillis: Long) {
        stopRequest.complete()

        val result = withTimeoutOrNull(gracePeriodMillis) {
            serverJob.join()
            true
        }

        if (result == null) {
            // timeout
            serverJob.cancel()

            withTimeoutOrNull(timeoutMillis - gracePeriodMillis) {
                serverJob.join()
            }
        }
    }

    override fun stop(gracePeriodMillis: Long, timeoutMillis: Long): Unit = runBlockingBridge {
        stopSuspend(gracePeriodMillis, timeoutMillis)
    }

    private fun CoroutineScope.startConnector(
        connectorSpec: EngineConnectorConfig,
        identity: TlsServerIdentity?
    ): HttpServer {
        return when (connectorSpec) {
            is UnixSocketConnectorConfig -> {
                val settings = UnixSocketServerSettings(
                    socketPath = connectorSpec.socketPath,
                    connectionIdleTimeoutSeconds = configuration.connectionIdleTimeoutSeconds.toLong(),
                )

                unixSocketServer(settings) { request ->
                    handleRequest(request, "http")
                }
            }

            else -> {
                val settings = HttpServerSettings(
                    host = connectorSpec.host,
                    port = connectorSpec.port,
                    connectionIdleTimeoutSeconds = configuration.connectionIdleTimeoutSeconds.toLong(),
                    reuseAddress = configuration.reuseAddress
                )

                if (identity != null) {
                    httpsServer(settings, identity) { request ->
                        handleRequest(request, "https")
                    }
                } else {
                    httpServer(settings) { request ->
                        handleRequest(request, "http")
                    }
                }
            }
        }
    }

    private fun addHandlerForExpectedHeader(output: ByteWriteChannel, call: KlioApplicationCall) {
        val continueResponse = "HTTP/1.1 100 Continue$CRLF$CRLF"
        val expectHeaderValue = "100-continue"

        val expectedHeaderPhase = PipelinePhase("ExpectedHeaderPhase")
        call.request.pipeline.insertPhaseBefore(ApplicationReceivePipeline.Before, expectedHeaderPhase)
        call.request.pipeline.intercept(expectedHeaderPhase) {
            val request = call.request
            val version = HttpProtocolVersion.parse(request.httpVersion)
            val expectHeader = call.request.headers[HttpHeaders.Expect]?.lowercase()
            val hasBody = hasBody(request)

            if (expectHeader == null || version == HttpProtocolVersion.HTTP_1_0 || !hasBody) {
                return@intercept
            }

            if (expectHeader != expectHeaderValue) {
                call.respond(HttpStatusCode.ExpectationFailed)
            } else {
                output.apply {
                    output.writeStringUtf8(continueResponse)
                    output.flush()
                }
            }
        }
    }

    private fun hasBody(request: KlioApplicationRequest): Boolean {
        val contentLength = request.headers[HttpHeaders.ContentLength]?.toLong()
        val transferEncoding = request.headers[HttpHeaders.TransferEncoding]
        return transferEncoding != null || (contentLength != null && contentLength > 0)
    }

    @OptIn(InternalAPI::class)
    private fun ServerRequestScope.setCloseHandler(call: KlioApplicationCall) {
        onClose = {
            val requestCloseHandler = call.attributes.getOrNull(HttpRequestCloseHandlerKey)
            requestCloseHandler?.invoke()
        }
    }

    private suspend fun ServerRequestScope.handleRequest(request: Request, scheme: String) {
        withContext(userDispatcher) requestContext@{
            val call = KlioApplicationCall(
                applicationProvider(),
                request,
                input,
                output,
                engineDispatcher,
                userDispatcher,
                upgraded,
                remoteAddress,
                localAddress,
                scheme,
                this@requestContext.coroutineContext
            )

            try {
                addHandlerForExpectedHeader(output, call)
                setCloseHandler(call)
                pipeline.execute(call)
            } catch (error: Throwable) {
                handleFailure(call, error)
            } finally {
                call.release()
            }
        }
    }

    private fun initServerJob(): Job {
        val environment = environment
        val userDispatcher = userDispatcher
        val stopRequest = stopRequest
        val startupJob = startupJob
        val cioConnectors = resolvedConnectorsDeferred

        return CoroutineScope(
            applicationProvider().parentCoroutineContext + engineDispatcher
        ).launch(start = CoroutineStart.LAZY) {
            val connectors = ArrayList<HttpServer>(configuration.connectors.size)
            val identities = ArrayList<TlsServerIdentity>()

            try {
                val connectorsAndServers = configuration.connectors.map { connectorSpec ->
                    val identity = (connectorSpec as? EngineSSLConnectorConfig)?.let { ssl ->
                        TlsServerIdentity(ssl.certificateChainPem, ssl.privateKeyPem).also { identities.add(it) }
                    }
                    connectorSpec to startConnector(connectorSpec, identity)
                }
                connectors.addAll(connectorsAndServers.map { it.second })

                val resolvedConnectors = connectorsAndServers
                    .map { (connector, server) -> connector to server.serverSocket.await() }
                    .map { (connector, socket) ->
                        socket.localAddress.port?.let { connector.withPort(it) } ?: connector
                    }
                cioConnectors.complete(resolvedConnectors)
            } catch (cause: Throwable) {
                connectors.forEach { it.rootServerJob.cancel() }
                identities.forEach { it.close() }
                stopRequest.completeExceptionally(cause)
                startupJob.completeExceptionally(cause)
                throw cause
            }

            startupJob.complete(Unit)
            stopRequest.join()

            // stopping
            connectors.forEach {
                it.acceptJob.cancel()
            }

            withContext(userDispatcher) {
                monitor.raise(ApplicationStopPreparing, environment)
            }
            connectors.map { it.rootServerJob }.joinAll()
            identities.forEach { it.close() }
        }
    }
}

/**
 * CIO's `httpServer` over TLS: each accepted connection completes a TLS
 * handshake before its request pipeline starts. A client that fails the
 * handshake, or does not finish it within the idle timeout, is dropped
 * without affecting other connections.
 */
@OptIn(InternalAPI::class)
private fun CoroutineScope.httpsServer(
    settings: HttpServerSettings,
    identity: TlsServerIdentity,
    handler: HttpRequestHandler
): HttpServer {
    val socket = CompletableDeferred<ServerSocket>()

    val serverLatch: CompletableJob = Job()

    val serverJob = launch(
        context = CoroutineName("server-root-$settings"),
        start = CoroutineStart.UNDISPATCHED
    ) {
        serverLatch.join()
    }

    val selector = SelectorManager(coroutineContext)
    val timeout = settings.connectionIdleTimeoutSeconds.seconds

    val rootConnectionJob = SupervisorJob(serverJob)
    val acceptJob = launch(serverJob + CoroutineName("accept-$settings")) {
        val serverSocket = aSocket(selector).tcp().bind(settings.host, settings.port) {
            reuseAddress = settings.reuseAddress
        }

        serverSocket.use { server ->
            socket.complete(server)

            val exceptionHandler = coroutineContext[CoroutineExceptionHandler]
                ?: DefaultUncaughtExceptionHandler(LOGGER)

            val connectionScope = CoroutineScope(
                coroutineContext +
                    rootConnectionJob +
                    exceptionHandler +
                    CoroutineName("request")
            )

            try {
                while (true) {
                    val client: Socket = try {
                        server.accept()
                    } catch (cause: IOException) {
                        LOGGER.trace("Failed to accept connection", cause)
                        continue
                    }

                    connectionScope.launch {
                        val secured = try {
                            withTimeout(timeout) { client.tlsServer(identity, connectionScope.coroutineContext) }
                        } catch (cause: Throwable) {
                            LOGGER.trace("TLS handshake failed", cause)
                            client.close()
                            return@launch
                        }

                        val connection = ServerIncomingConnection(
                            secured.openReadChannel(),
                            secured.openWriteChannel(),
                            client.remoteAddress.toNetworkAddress(),
                            client.localAddress.toNetworkAddress()
                        )

                        val clientJob = connectionScope.startServerConnectionPipeline(
                            connection,
                            timeout,
                            handler
                        )

                        clientJob.invokeOnCompletion {
                            secured.close()
                        }
                    }
                }
            } catch (closed: ClosedChannelException) {
                LOGGER.trace("Server socket closed", closed)
                coroutineContext.cancel()
            } finally {
                server.close()
                rootConnectionJob.complete()
                rootConnectionJob.join()
                server.awaitClosed()
            }
        }
    }

    acceptJob.invokeOnCompletion { cause ->
        cause?.let { socket.completeExceptionally(it) }
        serverLatch.complete()
    }

    serverJob.invokeOnCompletion {
        selector.close()
    }

    return HttpServer(serverJob, acceptJob, socket)
}

private const val CRLF = "\r\n"
