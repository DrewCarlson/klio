/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's counterpart of ktor-test-server's TestServer.kt and the Gradle
// service that starts it: the CIO application the client suites call at
// TEST_SERVER, the HTTP and SOCKS proxy test servers, and the TLS server at
// 8089, which upstream runs on Jetty with a certificate generated into a JVM
// keystore and klio runs on its `Klio` engine with the klio test CA's
// localhost certificate (tests/fixtures/tls/server-p256.pem). Upstream's
// HTTP/2 server (8084) needs Netty; klio has no HTTP/2 engine, so that port
// stays closed and the tests that use it are not run.

package test.server

import io.ktor.server.application.*
import io.ktor.server.cio.*
import io.ktor.server.engine.*
import io.ktor.server.engine.klio.*
import kotlinx.coroutines.*
import test.server.tests.socksServerHandler
import test.server.tests.tcpServerHandler

const val TEST_SERVER: String = "http://127.0.0.1:8080"

private const val DEFAULT_PORT: Int = 8080
private const val DEFAULT_TLS_PORT: Int = 8089
private const val HTTP_PROXY_PORT: Int = 8082
private const val SOCKS_PROXY_PORT: Int = 8083

internal fun startServer(scope: CoroutineScope, verbose: Boolean) {
    TestTcpServer(HTTP_PROXY_PORT, scope, ::tcpServerHandler)
    TestTcpServer(SOCKS_PROXY_PORT, scope, ::socksServerHandler)

    // Address reuse lets a census start the servers again on the same ports
    // right after stopping them.
    val servers = listOf(
        embeddedServer(
            CIO,
            configure = {
                connector { port = DEFAULT_PORT }
                reuseAddress = true
            },
            module = { tests(verbose) },
        ),
        setupTLSServer(DEFAULT_TLS_PORT, module = Application::tlsTests),
    )

    scope.launch(CoroutineName("server-stopper")) {
        try {
            awaitCancellation()
        } finally {
            servers.forEach { it.stop(gracePeriodMillis = 0, timeoutMillis = 0) }
        }
    }

    runBlocking {
        servers.map { async { it.start() } }
            .awaitAll()
    }
}

private fun setupTLSServer(
    @Suppress("SameParameterValue") port: Int,
    module: suspend Application.() -> Unit,
): EmbeddedServer<*, *> = embeddedServer(
    factory = Klio,
    configure = {
        sslConnector(TLS_CERTIFICATE_CHAIN, TLS_PRIVATE_KEY) {
            this.port = port
        }
        reuseAddress = true
    },
    module = module,
)

// The klio test CA's certificate for localhost, 127.0.0.1 and ::1, and its
// P-256 key (tests/fixtures/tls). Test-only.
private const val TLS_CERTIFICATE_CHAIN = """-----BEGIN CERTIFICATE-----
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
-----END CERTIFICATE-----"""

private const val TLS_PRIVATE_KEY = """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgg1TdpRDn7XHmlhw6
MDliVqe0iXT/cbjwR2mnKU7krW+hRANCAAQB+d9tbMrvCOFKq2l5+C4/A2/Mrrgx
oZNo6IUMsjHV3bxC23pjAuSKQiughfsy2/y9RN2y92qy2DGCo4brW450
-----END PRIVATE KEY-----"""
