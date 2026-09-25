// Run with: klio run --feature io.ktor/server-cio,server-websockets,client-cio examples/ktor_websocket_deflate.kt
// WebSocket compression (permessage-deflate, RFC 7692) between the CIO server
// and the CIO client. Both install WebSocketDeflateExtension; the handshake
// negotiates it, frames above the size threshold travel compressed (RSV1
// set) and smaller ones as they are, and each side sees the original text.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.websocket.webSocket
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import io.ktor.websocket.Frame
import io.ktor.websocket.WebSocketDeflateExtension
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.runBlocking
import io.ktor.client.plugins.websocket.WebSockets as ClientWebSockets

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

fun report(n: Int) = buildString {
    repeat(n) { append("row $it: all systems nominal, all systems nominal\n") }
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
        install(WebSockets) {
            extensions {
                install(WebSocketDeflateExtension) {
                    compressIfBiggerThan(64)
                }
            }
        }
        routing {
            webSocket("/reports") {
                val extensions = call.request.headers["Sec-WebSocket-Extensions"]
                send("client offered: $extensions")
                for (frame in incoming) {
                    if (frame !is Frame.Text) continue
                    val text = frame.readText()
                    if (text == "done") break
                    // Echo back a longer report built from the request.
                    send(report(text.length))
                }
            }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val client = HttpClient(io.ktor.client.engine.cio.CIO) {
            install(ClientWebSockets) {
                extensions {
                    install(WebSocketDeflateExtension)
                }
            }
        }
        client.webSocket(host = "127.0.0.1", port = port, path = "/reports") {
            println((incoming.receive() as Frame.Text).readText())
            for (size in listOf(3, 200, 1000)) {
                send("x".repeat(size))
                val text = (incoming.receive() as Frame.Text).readText()
                println("asked for $size rows: ${text.lines().size - 1} rows, intact ${text == report(size)}")
            }
            send("done")
        }
        client.close()
    }
    server.stop(100, 1000)
}
