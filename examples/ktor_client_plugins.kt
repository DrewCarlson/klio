// Run with: klio run --feature io.ktor/server-cio,server-auth,client-cio,client-auth,client-logging examples/ktor_client_plugins.kt
// The client's plugins against a CIO server built to exercise them:
// DefaultRequest fills in the base URL and a header, HttpRequestRetry
// retries a flaky endpoint, HttpTimeout cuts off a slow one, HttpCookies
// keeps a session cookie, Auth answers a bearer challenge and refreshes an
// expired token, and Logging records each request line.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.HttpRequestRetry
import io.ktor.client.plugins.HttpRequestTimeoutException
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.auth.Auth
import io.ktor.client.plugins.auth.providers.BearerTokens
import io.ktor.client.plugins.auth.providers.bearer
import io.ktor.client.plugins.cookies.HttpCookies
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.plugins.logging.LogLevel as ClientLogLevel
import io.ktor.client.plugins.logging.Logger as ClientLogger
import io.ktor.client.plugins.logging.Logging
import io.ktor.client.plugins.timeout
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.statement.bodyAsText
import io.ktor.http.Cookie
import io.ktor.http.HttpStatusCode
import io.ktor.server.application.install
import io.ktor.server.auth.Authentication
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.bearer
import io.ktor.server.auth.principal
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing
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
    var flakyCalls = 0
    val validTokens = mutableSetOf("fresh-token")
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
        install(Authentication) {
            bearer("api") {
                authenticate { credential ->
                    if (credential.token in validTokens) UserIdPrincipal("user-of-${credential.token}") else null
                }
            }
        }
        routing {
            get("/agent") { call.respondText("client says ${call.request.headers["X-Client"]}") }
            get("/flaky") {
                flakyCalls++
                if (flakyCalls < 3) {
                    call.respondText("try again", status = HttpStatusCode.ServiceUnavailable)
                } else {
                    call.respondText("ok after $flakyCalls calls")
                }
            }
            get("/slow") {
                delay(2_000)
                call.respondText("too late")
            }
            get("/login") {
                // A cookie without a path is kept for the path that set it.
                call.response.cookies.append(Cookie("session", "s-42", path = "/"))
                call.respondText("logged in")
            }
            get("/whoami") { call.respondText("session ${call.request.cookies["session"]}") }
            authenticate("api") {
                get("/secret") { call.respondText("secret for ${call.principal<UserIdPrincipal>()?.name}") }
            }
        }
    }.start(wait = false)

    val requestLines = mutableListOf<String>()
    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        val client = HttpClient(io.ktor.client.engine.cio.CIO) {
            defaultRequest {
                url("http://127.0.0.1:$port/")
                header("X-Client", "klio")
            }
            install(HttpRequestRetry) {
                retryOnServerErrors(maxRetries = 3)
                constantDelay(10)
            }
            install(HttpTimeout)
            install(HttpCookies)
            install(Auth) {
                bearer {
                    loadTokens { BearerTokens("stale-token", "refresh-1") }
                    refreshTokens { BearerTokens("fresh-token", "refresh-2") }
                    // The stale token goes out with the first request, so the
                    // server's challenge makes the client refresh it.
                    sendWithoutRequest { "secret" in it.url.encodedPathSegments }
                }
            }
            install(Logging) {
                level = ClientLogLevel.INFO
                logger = object : ClientLogger {
                    override fun log(message: String) {
                        message.lineSequence().firstOrNull { it.startsWith("REQUEST:") }?.let {
                            requestLines += it.substringBefore("http://") + it.substringAfter(":$port")
                        }
                    }
                }
            }
        }

        println(client.get("agent").bodyAsText())
        println(client.get("flaky").bodyAsText())
        try {
            client.get("slow") { timeout { requestTimeoutMillis = 200 } }
            println("slow: answered")
        } catch (cause: HttpRequestTimeoutException) {
            println("slow: timed out")
        }
        println(client.get("login").bodyAsText())
        println(client.get("whoami").bodyAsText())
        println(client.get("secret").bodyAsText())
        client.close()
    }
    server.stop(100, 1000)
    println("logged requests:")
    requestLines.forEach { println("  $it") }
}
