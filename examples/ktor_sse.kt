// Run with: klio run --feature io.ktor/server-cio,server-sse,client-cio examples/ktor_sse.kt
// Server-sent events between the CIO server and the CIO client. The server's
// SSE route streams events with ids, event names and multi-line data, with a
// pause between them; the client's SSE plugin reads them as they arrive and
// sees the stream end when the server closes it. A second route reads a
// query parameter and closes after a countdown.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.sse.SSE as ClientSSE
import io.ktor.client.plugins.sse.sse
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.sse.SSE
import io.ktor.server.sse.sse
import io.ktor.sse.ServerSentEvent
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

class QuietLogger : Logger {
    override val level: LogLevel = LogLevel.ERROR
    override fun error(message: String) {}
    override fun error(message: String, cause: Throwable) {}
    override fun warn(message: String) {}
    override fun warn(message: String, cause: Throwable) {}
    override fun info(message: String) {}
    override fun info(message: String, cause: Throwable) {}
    override fun debug(message: String) {}
    override fun debug(message: String, cause: Throwable) {}
    override fun trace(message: String) {}
    override fun trace(message: String, cause: Throwable) {}
}

fun main() {
    val server = embeddedServer(
        CIO,
        applicationEnvironment { log = QuietLogger() },
        configure = {
            connector {
                host = "127.0.0.1"
                port = 0
            }
        }
    ) {
        install(SSE)
        routing {
            sse("/news") {
                send(ServerSentEvent("klio 1.0 released", event = "release", id = "1"))
                delay(50)
                send(ServerSentEvent("line one\nline two", event = "note", id = "2"))
                delay(50)
                send(ServerSentEvent(data = "bye", id = "3"))
            }
            sse("/countdown") {
                val from = call.parameters["from"]?.toInt() ?: 3
                for (n in from downTo 1) send(ServerSentEvent(n.toString()))
                send(ServerSentEvent("liftoff", event = "done"))
            }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val client = HttpClient(io.ktor.client.engine.cio.CIO) {
            install(ClientSSE)
        }
        client.sse(host = "127.0.0.1", port = port, path = "/news") {
            println("content type: ${call.response.headers["Content-Type"]}")
            incoming.collect { event ->
                println("id=${event.id} event=${event.event} data=${event.data?.replace("\n", "\\n")}")
            }
        }
        println("news stream ended")
        client.sse(host = "127.0.0.1", port = port, path = "/countdown?from=4") {
            val data = mutableListOf<String>()
            incoming.collect { event -> data += event.data.orEmpty() }
            println("countdown: $data")
        }
        client.close()
    }
    server.stop(100, 1000)
}
