// Run with: klio run --feature io.ktor/server-cio,client-cio examples/ktor_many_connections.kt
// Many short connections at once between the CIO server and the CIO client in
// one program. Without pipelining the client gives every request its own
// connection, so 16 coroutines making 50 requests each open and close 800
// sockets while others are in use: a descriptor the system hands out again
// right after a close must reach its new socket untouched by the old one.

import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.server.application.ApplicationEnvironment
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveText
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking

object QuietLogger : Logger {
    override val level: LogLevel = LogLevel.ERROR
    override fun error(message: String) = println("server error: $message")
    override fun error(message: String, cause: Throwable) = println("server error: $message: $cause")
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
        applicationEnvironment { log = QuietLogger },
        configure = {
            connector {
                host = "127.0.0.1"
                port = 0
            }
        }
    ) {
        routing {
            get("/square/{n}") {
                val n = call.parameters["n"]!!.toInt()
                call.respondText("${n * n}")
            }
            post("/echo") {
                call.respondText(call.receiveText().reversed())
            }
        }
    }.start(wait = false)

    runBlocking {
        val base = "http://127.0.0.1:${server.engine.resolvedConnectors().single().port}"
        val client = HttpClient(io.ktor.client.engine.cio.CIO)
        val workers = (0 until 16).map { w ->
            async {
                var sum = 0L
                var echoed = 0
                for (i in 0 until 50) {
                    val n = w * 50 + i
                    if (i % 2 == 0) {
                        sum += client.get("$base/square/$n").bodyAsText().toLong()
                    } else {
                        val body = "request $n from worker $w"
                        if (client.post("$base/echo") { setBody(body) }.bodyAsText() == body.reversed()) echoed++
                    }
                }
                w to (sum to echoed)
            }
        }
        for ((w, result) in workers.awaitAll()) {
            println("worker $w: sum of squares ${result.first}, echoes ${result.second}/25")
        }
        client.close()
    }
    server.stop(0, 0)
    println("done")
}
