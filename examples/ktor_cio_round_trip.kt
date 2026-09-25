// Run with: klio run --feature io.ktor/server-cio,client-cio examples/ktor_cio_round_trip.kt
// The CIO server and the CIO client, both upstream Ktor, talking over klio's
// sockets on an ephemeral loopback port: routing with path parameters, a
// request body, a status code, a response streamed in chunks and a binary
// body. Without pipelining (which upstream CIO supports only on the JVM) the
// client gives every request its own connection, as a plugin that records the
// client port of each call shows. The server's log goes to a recording
// logger, since its lines carry the port and timings.

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.createApplicationPlugin
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveText
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import io.ktor.utils.io.writeStringUtf8
import kotlinx.coroutines.runBlocking

class RecordingLogger : Logger {
    val lines = mutableListOf<String>()
    override val level: LogLevel = LogLevel.INFO
    override fun error(message: String) { lines += message }
    override fun error(message: String, cause: Throwable) { lines += message }
    override fun warn(message: String) { lines += message }
    override fun warn(message: String, cause: Throwable) { lines += message }
    override fun info(message: String) { lines += message }
    override fun info(message: String, cause: Throwable) { lines += message }
    override fun debug(message: String) {}
    override fun debug(message: String, cause: Throwable) {}
    override fun trace(message: String) {}
    override fun trace(message: String, cause: Throwable) {}
}

fun main() {
    val log = RecordingLogger()
    val clientPorts = mutableSetOf<Int>()
    val recordConnections = createApplicationPlugin("RecordConnections") {
        onCall { call -> clientPorts += call.request.local.remotePort }
    }
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
        install(recordConnections)
        routing {
            get("/hello/{name}") { call.respondText("Hello, ${call.parameters["name"]}!") }
            post("/reverse") { call.respondText(call.receiveText().reversed()) }
            get("/accepted") { call.respond(HttpStatusCode.Accepted, "queued") }
            get("/stream") {
                call.respondBytesWriter(contentType = ContentType.Text.Plain) {
                    repeat(3) { index ->
                        writeStringUtf8("chunk $index\n")
                        flush()
                    }
                }
            }
            get("/bytes") { call.respondBytes(ByteArray(256) { it.toByte() }, ContentType.Application.OctetStream) }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val base = "http://127.0.0.1:$port"
        val client = HttpClient(io.ktor.client.engine.cio.CIO)

        val hello = client.get("$base/hello/klio")
        println("${hello.status.value} ${hello.bodyAsText()}")

        val reversed = client.post("$base/reverse") { setBody("stressed") }
        println("${reversed.status.value} ${reversed.bodyAsText()}")

        val accepted = client.get("$base/accepted")
        println("${accepted.status} ${accepted.bodyAsText()}")

        val stream = client.get("$base/stream")
        println("streamed with ${stream.headers[HttpHeaders.TransferEncoding]} encoding:")
        print(stream.bodyAsText())

        val bytes = client.get("$base/bytes").bodyAsBytes()
        println("binary body: ${bytes.size} bytes, last ${bytes.last()}")

        val missing = client.get("$base/missing")
        println("missing route: ${missing.status}")

        client.close()
    }
    server.stop(100, 1000)
    println("connections for 6 requests: ${clientPorts.size}")
    println("server logged its start: ${log.lines.any { it.startsWith("Responding at http://127.0.0.1:") }}")
}
