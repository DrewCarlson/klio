// Run with: klio run --feature io.ktor/server-cio,server-call-logging,server-call-id,client-cio examples/ktor_call_logging.kt
// CallLogging on the CIO server. Each completed call is logged with its
// status, method, path and time; a filter leaves out the health check; the
// MDC carries the call id and the path into every line logged during the
// call, including one logged after a switch to another dispatcher. The
// logger is an io.ktor.util.logging.Logger that reads klio.logging.MDC, where
// a JVM program would configure an slf4j backend to print the MDC.
//
// The server logs a call after its response is sent, so the client may
// already be on its next request; the lines are printed after the server
// stops, ordered by call id.

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.server.application.install
import io.ktor.server.application.log
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.callid.CallId
import io.ktor.server.plugins.callid.callIdMdc
import io.ktor.server.plugins.callid.generate
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.request.path
import io.ktor.server.response.respondRedirect
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import klio.logging.MDC
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class MdcLogger : Logger {
    val lines = mutableListOf<Pair<String, String>>()
    override val level: LogLevel = LogLevel.TRACE

    private fun add(level: String, message: String) {
        val mdc = MDC.getCopyOfContextMap() ?: return
        val callId = mdc["call-id"] ?: return
        val entries = mdc.entries.sortedBy { it.key }.joinToString { "${it.key}=${it.value}" }
        synchronized(lines) { lines += callId to "$level $message {$entries}" }
    }

    override fun error(message: String) = add("ERROR", message)
    override fun error(message: String, cause: Throwable) = add("ERROR", message)
    override fun warn(message: String) = add("WARN", message)
    override fun warn(message: String, cause: Throwable) = add("WARN", message)
    override fun info(message: String) = add("INFO", message)
    override fun info(message: String, cause: Throwable) = add("INFO", message)
    override fun debug(message: String) = add("DEBUG", message)
    override fun debug(message: String, cause: Throwable) = add("DEBUG", message)
    override fun trace(message: String) = add("TRACE", message)
    override fun trace(message: String, cause: Throwable) = add("TRACE", message)
}

fun main() {
    val log = MdcLogger()
    var calls = 0
    val server = embeddedServer(
        CIO,
        applicationEnvironment { this.log = log },
        configure = {
            connector {
                host = "127.0.0.1"
                port = 0
            }
        }
    ) {
        install(CallId) {
            generate { "call-${++calls}" }
        }
        install(CallLogging) {
            clock { 0 }
            disableDefaultColors()
            callIdMdc("call-id")
            mdc("path") { it.request.path() }
            filter { it.request.path() != "/health" }
        }
        routing {
            get("/hello/{name}") {
                call.application.log.info("greeting ${call.parameters["name"]}")
                withContext(Dispatchers.Default) {
                    call.application.log.info("still in the call on another dispatcher")
                }
                call.respondText("Hello, ${call.parameters["name"]}!")
            }
            get("/health") { call.respondText("ok") }
            get("/old") { call.respondRedirect("/hello/klio") }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val client = HttpClient(io.ktor.client.engine.cio.CIO) { followRedirects = false }
        for (path in listOf("/hello/klio", "/health", "/old", "/missing")) {
            val response = client.get("http://127.0.0.1:$port$path")
            println("$path -> ${response.status.value} ${response.headers[HttpHeaders.Location] ?: response.bodyAsText()}")
        }
        client.close()
    }
    server.stop(100, 1000)

    println("server log:")
    for ((_, line) in log.lines.sortedBy { it.first.removePrefix("call-").toInt() }) println("  $line")
}
