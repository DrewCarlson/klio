// Run with: klio run --feature io.ktor/server-cio,server-auth,server-sessions,server-cors,client-cio examples/ktor_server_auth.kt
// Server-side authentication on the CIO server: basic auth checks a user
// table, a form login starts a cookie session that later requests
// authenticate with, and CORS answers a browser's preflight for one allowed
// origin and refuses another. The clients are the CIO client with plain
// headers, as curl would send them, and one that keeps cookies.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.cookies.HttpCookies
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.options
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.parameters
import io.ktor.http.setCookie
import io.ktor.server.application.install
import io.ktor.server.auth.Authentication
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.basic
import io.ktor.server.auth.form
import io.ktor.server.auth.principal
import io.ktor.server.auth.session
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.cors.routing.CORS
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.server.sessions.Sessions
import io.ktor.server.sessions.cookie
import io.ktor.server.sessions.sessions
import io.ktor.server.sessions.set
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable

@Serializable
data class UserSession(val name: String, val visits: Int)

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
    val users = mapOf("ada" to "lovelace", "alan" to "turing")
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
        install(CORS) {
            allowHost("app.example.com", schemes = listOf("https"))
            allowHeader(HttpHeaders.Authorization)
        }
        install(Sessions) {
            cookie<UserSession>("user_session") { cookie.path = "/" }
        }
        install(Authentication) {
            basic("basic") {
                realm = "klio"
                validate { credentials ->
                    if (users[credentials.name] == credentials.password) UserIdPrincipal(credentials.name) else null
                }
            }
            form("login") {
                userParamName = "user"
                passwordParamName = "password"
                validate { credentials ->
                    if (users[credentials.name] == credentials.password) UserIdPrincipal(credentials.name) else null
                }
                challenge { call.respondText("bad login", status = io.ktor.http.HttpStatusCode.Unauthorized) }
            }
            session<UserSession>("session") {
                validate { session -> session.copy(visits = session.visits + 1) }
                challenge { call.respondText("no session", status = io.ktor.http.HttpStatusCode.Unauthorized) }
            }
        }
        routing {
            authenticate("basic") {
                get("/basic") { call.respondText("hello ${call.principal<UserIdPrincipal>()?.name}") }
            }
            authenticate("login") {
                post("/login") {
                    val name = call.principal<UserIdPrincipal>()!!.name
                    call.sessions.set(UserSession(name, 0))
                    call.respondText("welcome $name")
                }
            }
            authenticate("session") {
                get("/profile") {
                    val session = call.principal<UserSession>()!!
                    call.sessions.set(session)
                    call.respondText("${session.name}, visit ${session.visits}")
                }
            }
        }
    }.start(wait = false)

    runBlocking {
        val base = "http://127.0.0.1:${server.engine.resolvedConnectors().single().port}"
        val client = HttpClient(io.ktor.client.engine.cio.CIO)

        val anonymous = client.get("$base/basic")
        println("basic, no credentials: ${anonymous.status.value} ${anonymous.headers[HttpHeaders.WWWAuthenticate]}")
        val ada = client.get("$base/basic") { header(HttpHeaders.Authorization, "Basic YWRhOmxvdmVsYWNl") }
        println("basic, ada: ${ada.status.value} ${ada.bodyAsText()}")
        val wrong = client.get("$base/basic") { header(HttpHeaders.Authorization, "Basic YWRhOnBhc3N3b3Jk") }
        println("basic, wrong password: ${wrong.status.value}")

        val badLogin = client.submitForm("$base/login", parameters {
            append("user", "alan")
            append("password", "enigma")
        })
        println("form login, wrong password: ${badLogin.status.value} ${badLogin.bodyAsText()}")
        // A browser-like client keeps the session cookie between requests.
        val browser = HttpClient(io.ktor.client.engine.cio.CIO) { install(HttpCookies) }
        val login = browser.submitForm("$base/login", parameters {
            append("user", "alan")
            append("password", "turing")
        })
        println("form login: ${login.status.value} ${login.bodyAsText()}, cookie ${login.setCookie().single().name}")
        repeat(2) {
            println("profile: ${browser.get("$base/profile").bodyAsText()}")
        }
        browser.close()
        println("profile, no cookie: ${client.get("$base/profile").bodyAsText()}")

        val preflight = client.options("$base/basic") {
            header(HttpHeaders.Origin, "https://app.example.com")
            header(HttpHeaders.AccessControlRequestMethod, HttpMethod.Get.value)
            header(HttpHeaders.AccessControlRequestHeaders, HttpHeaders.Authorization)
        }
        println(
            "preflight from app.example.com: ${preflight.status.value} " +
                "allow-origin=${preflight.headers[HttpHeaders.AccessControlAllowOrigin]} " +
                "allow-headers=${preflight.headers[HttpHeaders.AccessControlAllowHeaders]}"
        )
        val foreign = client.options("$base/basic") {
            header(HttpHeaders.Origin, "https://evil.example.com")
            header(HttpHeaders.AccessControlRequestMethod, HttpMethod.Get.value)
        }
        println("preflight from evil.example.com: ${foreign.status.value}")
        client.close()
    }
    server.stop(100, 1000)
}
