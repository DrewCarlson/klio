// Run with: klio run --feature io.ktor/server-cio,server-websockets,client-cio examples/ktor_websockets.kt
// WebSockets between the `Klio` server engine and the CIO client, both over
// plain TCP (ws://) and over TLS (wss://). One server serves an HTTP and an
// HTTPS connector; its echo route greets the client with the scheme it came
// in on, echoes text frames, answers a 70,000-byte binary frame with its size
// and checksum, and closes the session with a reason when the client says
// "bye". The client trusts the test CA for wss.
//
// The certificates are the test fixtures from tests/fixtures/tls (a P-256
// CA and the P-256 server certificate it issued for localhost, 127.0.0.1
// and ::1). Their keys are for tests only.

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.ws
import io.ktor.client.plugins.websocket.wss
import io.ktor.network.tls.addTrustedCertificates
import io.ktor.server.application.install
import io.ktor.server.engine.ConnectorType
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.engine.klio.Klio
import io.ktor.server.engine.sslConnector
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import io.ktor.websocket.CloseReason
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readBytes
import io.ktor.websocket.readText
import io.ktor.websocket.send
import kotlinx.coroutines.runBlocking
import io.ktor.client.plugins.websocket.WebSockets as ClientWebSockets

const val TEST_CA = """
-----BEGIN CERTIFICATE-----
MIIBlTCCATugAwIBAgIUHoalZArR8tNgeesuP4cyRg74Q+owCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMa2xpbyB0ZXN0IENBMCAXDTI2MDkyNTE3MTEzMFoYDzIwOTUw
MzA3MTcxMTMwWjAXMRUwEwYDVQQDDAxrbGlvIHRlc3QgQ0EwWTATBgcqhkjOPQIB
BggqhkjOPQMBBwNCAAQUO+OkccrHIzFtD5Sqr82o2qR8hbD7ikqTPEhA2mkxxf8E
Ju2pWT/UHpp0fdPmsCGcXiIGaAUg89eOwk8l7ghgo2MwYTAdBgNVHQ4EFgQU6wWF
sjncXIS5HmPDqHkjKvDQ924wHwYDVR0jBBgwFoAU6wWFsjncXIS5HmPDqHkjKvDQ
924wDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwCgYIKoZIzj0EAwID
SAAwRQIhAJENHGbDQ0xrVdBwkgftkZjDKzGjcH2KGRToxqImTmlpAiA6So9nfaRk
/GSCWUXluOXRUEXVn4yfLYa8unzk97dyvA==
-----END CERTIFICATE-----
"""

const val SERVER_CHAIN = """
-----BEGIN CERTIFICATE-----
MIIB0TCCAXegAwIBAgIUGMlE1Z5OQ1bMkm56XZh8mpj1g4YwCgYIKoZIzj0EAwIw
FzEVMBMGA1UEAwwMa2xpbyB0ZXN0IENBMCAXDTI2MDkyNTE3MTEzMFoYDzIwOTUw
MzA3MTcxMTMwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwWTATBgcqhkjOPQIBBggq
hkjOPQMBBwNCAAQB+d9tbMrvCOFKq2l5+C4/A2/MrrgxoZNo6IUMsjHV3bxC23pj
AuSKQiughfsy2/y9RN2y92qy2DGCo4brW450o4GhMIGeMCwGA1UdEQQlMCOCCWxv
Y2FsaG9zdIcEfwAAAYcQAAAAAAAAAAAAAAAAAAAAATAJBgNVHRMEAjAAMA4GA1Ud
DwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQUJCi1GBpC
oGudb20KThQADr4q7JswHwYDVR0jBBgwFoAU6wWFsjncXIS5HmPDqHkjKvDQ924w
CgYIKoZIzj0EAwIDSAAwRQIgVfZyRSgwnOkzECKjscptHfH3Ir3NKfuPHFjjAPJr
568CIQDr8njHR2WcZarqx5P8RzG2tAAMUC9KAlBVzhcqBZ2A1g==
-----END CERTIFICATE-----
"""

const val SERVER_KEY = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgg1TdpRDn7XHmlhw6
MDliVqe0iXT/cbjwR2mnKU7krW+hRANCAAQB+d9tbMrvCOFKq2l5+C4/A2/Mrrgx
oZNo6IUMsjHV3bxC23pjAuSKQiughfsy2/y9RN2y92qy2DGCo4brW450
-----END PRIVATE KEY-----
"""

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

// One conversation, run over ws:// and over wss://.
suspend fun DefaultClientWebSocketSession.converse(scheme: String) {
    println("[$scheme] ${(incoming.receive() as Frame.Text).readText()}")
    for (word in listOf("hello", "klio")) {
        send(word)
        println("[$scheme] ${(incoming.receive() as Frame.Text).readText()}")
    }
    send(Frame.Binary(true, ByteArray(70_000) { (it % 251).toByte() }))
    println("[$scheme] ${(incoming.receive() as Frame.Text).readText()}")
    send("bye")
    val reason = closeReason.await()
    println("[$scheme] closed by the server: ${reason?.knownReason} ${reason?.message}")
}

fun main() {
    val log = RecordingLogger()
    val server = embeddedServer(Klio, applicationEnvironment { this.log = log }, configure = {
        connector {
            host = "127.0.0.1"
            port = 0
        }
        sslConnector(SERVER_CHAIN, SERVER_KEY) {
            host = "127.0.0.1"
            port = 0
        }
    }) {
        install(WebSockets) {
            maxFrameSize = 1L shl 20
        }
        routing {
            webSocket("/echo") {
                send("welcome over ${call.request.local.scheme}")
                for (frame in incoming) {
                    when (frame) {
                        is Frame.Text -> {
                            val text = frame.readText()
                            if (text == "bye") {
                                close(CloseReason(CloseReason.Codes.NORMAL, "goodbye"))
                            } else {
                                send("echo: $text")
                            }
                        }
                        is Frame.Binary -> {
                            val bytes = frame.readBytes()
                            send("binary: ${bytes.size} bytes, checksum ${bytes.sumOf { it.toInt() and 0xff }}")
                        }
                        else -> {}
                    }
                }
            }
        }
    }.start(wait = false)

    runBlocking {
        val connectors = server.engine.resolvedConnectors()
        val plainPort = connectors.first { it.type == ConnectorType.HTTP }.port
        val tlsPort = connectors.first { it.type == ConnectorType.HTTPS }.port

        HttpClient(CIO) {
            install(ClientWebSockets)
            engine {
                https { addTrustedCertificates(TEST_CA) }
            }
        }.use { client ->
            client.ws(host = "127.0.0.1", port = plainPort, path = "/echo") { converse("ws") }
            client.wss(host = "localhost", port = tlsPort, path = "/echo") { converse("wss") }
        }
    }
    server.stop(0, 500)
    println("server errors: ${log.lines.count { it.contains("error", ignoreCase = true) || it.contains("exception", ignoreCase = true) }}")
}
