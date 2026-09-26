// Run with: klio run --feature io.ktor/server-cio,server-auth,client-cio,client-auth examples/ktor_digest_auth.kt
// HTTP digest authentication on both sides: a CIO server with MD5 and
// SHA-256 digest providers whose user table holds H(user:realm:password),
// and a client whose Auth plugin answers the server's challenge with qop=auth.
// The server answers a verified request with Authentication-Info, and a wrong
// password gets the challenge again, as a 401.

import io.ktor.client.HttpClient
import io.ktor.client.plugins.auth.Auth
import io.ktor.client.plugins.auth.providers.DigestAuthCredentials
import io.ktor.client.plugins.auth.providers.digest
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText
import io.ktor.http.HttpHeaders
import io.ktor.server.application.install
import io.ktor.server.auth.Authentication
import io.ktor.server.auth.UserIdPrincipal
import io.ktor.server.auth.authenticate
import io.ktor.server.auth.digest
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
import io.ktor.utils.io.core.toByteArray
import kotlinx.coroutines.runBlocking
import klio.security.MessageDigest

const val REALM = "klio@example"

fun hash(algorithm: String, user: String, password: String): ByteArray =
    MessageDigest.getInstance(algorithm).digest("$user:$REALM:$password".toByteArray())

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

fun ByteArray.hex(): String = joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

fun main() {
    println("MD5(alice:$REALM:wonderland) = ${hash("MD5", "alice", "wonderland").hex()}")

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
            digest("md5") {
                realm = REALM
                algorithmName = "MD5"
                digestProvider { userName, _ -> if (userName == "alice") hash("MD5", "alice", "wonderland") else null }
                validate { credentials -> UserIdPrincipal(credentials.userName) }
            }
            digest("sha256") {
                realm = REALM
                algorithmName = "SHA-256"
                digestProvider { userName, _ -> if (userName == "bob") hash("SHA-256", "bob", "builder") else null }
                validate { credentials -> UserIdPrincipal(credentials.userName) }
            }
        }
        routing {
            authenticate("md5") {
                get("/md5") { call.respondText("md5 area for ${call.principal<UserIdPrincipal>()?.name}") }
            }
            authenticate("sha256") {
                get("/sha256") { call.respondText("sha-256 area for ${call.principal<UserIdPrincipal>()?.name}") }
            }
        }
    }.start(wait = false)

    runBlocking {
        val port = server.engine.resolvedConnectors().single().port
        fun client(user: String, password: String, algorithm: String = "MD5") =
            HttpClient(io.ktor.client.engine.cio.CIO) {
                install(Auth) {
                    digest {
                        algorithmName = algorithm
                        credentials { DigestAuthCredentials(user, password) }
                        realm = REALM
                    }
                }
            }

        val alice = client("alice", "wonderland")
        val response = alice.get("http://127.0.0.1:$port/md5")
        println(response.bodyAsText())
        // The server proves it knows the password too: Authentication-Info
        // carries rspauth, the digest over the same qop, count and cnonce.
        val info = response.headers[HttpHeaders.AuthenticationInfo].orEmpty()
            .split(", ").associate { it.substringBefore('=') to it.substringAfter('=').trim('"') }
        println("authentication-info: qop=${info["qop"]} nc=${info["nc"]} rspauth ${info["rspauth"]?.length} hex digits")
        alice.close()

        val bob = client("bob", "builder", "SHA-256")
        println(bob.get("http://127.0.0.1:$port/sha256").bodyAsText())
        bob.close()

        val mallory = client("alice", "guess")
        println("wrong password: ${mallory.get("http://127.0.0.1:$port/md5").status}")
        mallory.close()
    }
    server.stop(100, 1000)
}
