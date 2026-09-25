// Run with: klio run --feature io.ktor/server-cio,client-cio examples/ktor_https_round_trip.kt
// An HTTPS round trip in one process: the `Klio` server engine serves an
// HTTPS connector from a PEM certificate chain and key, and the CIO client
// trusts the test CA that issued it, by name and by IP address. A client that
// does not trust the CA is refused, and so is one that expects another host
// name. The server's log goes to a recording logger, since its lines carry
// the ephemeral port.
//
// The certificates are the test fixtures from tests/fixtures/tls (a P-256
// CA and the P-256 server certificate it issued for localhost, 127.0.0.1
// and ::1). Their keys are for tests only.

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.network.tls.addTrustedCertificates
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.embeddedServer
import io.ktor.server.engine.klio.Klio
import io.ktor.server.engine.sslConnector
import io.ktor.server.request.httpVersion
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import kotlinx.coroutines.runBlocking

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

fun main() {
    val log = RecordingLogger()
    val server = embeddedServer(Klio, applicationEnvironment { this.log = log }, configure = {
        sslConnector(SERVER_CHAIN, SERVER_KEY) {
            host = "127.0.0.1"
            port = 0
        }
    }) {
        routing {
            get("/hello") {
                call.respondText("hello over ${call.request.httpVersion} and TLS")
            }
            post("/echo") {
                call.respondText("echo: " + call.receiveText())
            }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().first().port
        HttpClient(CIO) {
            engine {
                https { addTrustedCertificates(TEST_CA) }
            }
        }.use { client ->
            println(client.get("https://localhost:$port/hello").bodyAsText())
            println(client.get("https://127.0.0.1:$port/hello").bodyAsText())
            val big = "x".repeat(100_000)
            val echoed = client.post("https://localhost:$port/echo") { setBody(big) }.bodyAsText()
            println("echoed ${echoed.length} characters")
        }

        // Without the CA the server's certificate is not trusted.
        HttpClient(CIO) {
            engine { https { useSystemTrustStore = false } }
        }.use { client ->
            try {
                client.get("https://localhost:$port/hello")
                println("untrusted: accepted")
            } catch (cause: Exception) {
                println("untrusted: ${cause::class.simpleName}: ${cause.message}")
            }
        }

        // The certificate is not issued for this name.
        HttpClient(CIO) {
            engine {
                https {
                    addTrustedCertificates(TEST_CA)
                    serverName = "example.com"
                }
            }
        }.use { client ->
            try {
                client.get("https://localhost:$port/hello")
                println("wrong host: accepted")
            } catch (cause: Exception) {
                println("wrong host: ${cause::class.simpleName}: ${cause.message}")
            }
        }
    }
    server.stop(0, 500)
    println("server responded at https: " + log.lines.any { it.startsWith("Responding at https://127.0.0.1:") })
}
