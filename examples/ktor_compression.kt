// Run with: klio run --feature io.ktor/server-cio,server-compression,client-cio,client-encoding examples/ktor_compression.kt
// gzip and deflate between the CIO server and the CIO client, both upstream
// Ktor. The server's Compression plugin compresses responses the client
// accepts and decompresses request bodies; the client's ContentEncoding
// plugin sends Accept-Encoding, decodes responses and, in `Mode.All`,
// compresses a request body on demand. A client without the plugin sees the gzip bytes on the
// wire, and `GZipEncoder` decodes them directly.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.compression.ContentEncoding
import io.ktor.client.plugins.compression.ContentEncodingConfig
import io.ktor.client.plugins.compression.appliedDecoders
import io.ktor.client.plugins.compression.compress
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsBytes
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.compression.Compression
import io.ktor.server.plugins.compression.appliedDecoders
import io.ktor.server.plugins.compression.deflate
import io.ktor.server.plugins.compression.gzip
import io.ktor.server.plugins.compression.minimumSize
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.util.GZipEncoder
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.toByteArray
import kotlinx.coroutines.runBlocking

val report = buildString {
    for (day in 1..400) append("day $day: ${day * 37 % 100} requests served\n")
}

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
        install(Compression) {
            gzip { priority = 1.0 }
            deflate {
                priority = 0.5
                minimumSize(1024)
            }
        }
        routing {
            get("/report") { call.respondText(report) }
            get("/short") { call.respondText("tiny") }
            post("/upload") {
                val text = call.receiveText()
                call.respondText("received ${text.length} characters, decoded by ${call.request.appliedDecoders}")
            }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val base = "http://127.0.0.1:$port"

        val client = HttpClient(io.ktor.client.engine.cio.CIO) {
            install(ContentEncoding) {
                mode = ContentEncodingConfig.Mode.All
                gzip()
                deflate(0.5f)
            }
        }
        val gzipped = client.get("$base/report")
        println("report: decoded by ${gzipped.appliedDecoders}, intact ${gzipped.bodyAsText() == report}")

        val deflated = client.get("$base/report") { header(HttpHeaders.AcceptEncoding, "deflate") }
        println("report as deflate: decoded by ${deflated.appliedDecoders}, intact ${deflated.bodyAsText() == report}")

        val short = client.get("$base/short") { header(HttpHeaders.AcceptEncoding, "deflate") }
        println("short body under deflate's minimum size: ${short.bodyAsText()}, decoded by ${short.appliedDecoders}")

        val upload = client.post("$base/upload") {
            setBody(report)
            compress("gzip")
        }
        println(upload.bodyAsText())
        client.close()

        val plain = HttpClient(io.ktor.client.engine.cio.CIO)
        val raw = plain.get("$base/report") { header(HttpHeaders.AcceptEncoding, "gzip") }
        val wire = raw.bodyAsBytes()
        println("on the wire: ${raw.headers[HttpHeaders.ContentEncoding]}, under a fifth of the text: ${wire.size * 5 < report.length}")
        println("gzip magic: ${wire[0].toInt() and 0xff} ${wire[1].toInt() and 0xff}")
        val decoded = GZipEncoder.decode(ByteReadChannel(wire)).toByteArray().decodeToString()
        println("GZipEncoder decodes the wire bytes: ${decoded == report}")
        plain.close()
    }
    server.stop(100, 1000)
    println("server errors: ${log.lines.count { it.contains("error", ignoreCase = true) }}")
}
