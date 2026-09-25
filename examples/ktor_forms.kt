// Run with: klio run --feature io.ktor/server-cio,client-cio examples/ktor_forms.kt
// Form posts between the CIO client and the CIO server: a URL-encoded form
// read with receiveParameters, and a multipart form with text fields and a
// file part read with receiveMultipart, which parses the parts as they arrive.
// The same multipart body read as parameters keeps only its text fields.

import io.ktor.client.HttpClient
import io.ktor.client.request.forms.formData
import io.ktor.client.request.forms.submitForm
import io.ktor.client.request.forms.submitFormWithBinaryData
import io.ktor.client.statement.bodyAsText
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.content.PartData
import io.ktor.http.content.forEachPart
import io.ktor.http.parameters
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.request.receiveMultipart
import io.ktor.server.request.receiveParameters
import io.ktor.server.response.respondText
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import io.ktor.utils.io.readRemaining
import kotlinx.coroutines.runBlocking
import kotlinx.io.readByteArray

class QuietLogger : Logger {
    override val level: LogLevel = LogLevel.ERROR
    override fun error(message: String) = println("server error: $message")
    override fun error(message: String, cause: Throwable) = println("server error: $message")
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
        applicationEnvironment { log = QuietLogger() },
        configure = {
            connector {
                host = "127.0.0.1"
                port = 0
            }
        }
    ) {
        routing {
            post("/login") {
                val form = call.receiveParameters()
                call.respondText("user=${form["user"]} remember=${form["remember"]}")
            }
            post("/upload") {
                val lines = mutableListOf<String>()
                call.receiveMultipart().forEachPart { part ->
                    when (part) {
                        is PartData.FormItem -> lines += "field ${part.name} = ${part.value}"
                        is PartData.FileItem -> {
                            val bytes = part.provider().readRemaining().readByteArray()
                            lines += "file ${part.name} (${part.originalFileName}, ${part.contentType}): " +
                                "${bytes.size} bytes, sum ${bytes.sumOf { it.toInt() and 0xff }}"
                        }
                        else -> lines += "other part ${part.name}"
                    }
                    part.dispose()
                }
                call.respondText(lines.joinToString("\n"))
            }
            post("/fields") {
                val form = call.receiveParameters()
                call.respondText(form.names().sorted().joinToString { "$it=${form[it]}" })
            }
        }
    }.start(wait = false)

    runBlocking {
        val base = "http://127.0.0.1:${server.engine.resolvedConnectors().single().port}"
        val client = HttpClient(io.ktor.client.engine.cio.CIO)

        val login = client.submitForm("$base/login", parameters {
            append("user", "klio & friends")
            append("remember", "yes")
        })
        println(login.bodyAsText())

        val photo = ByteArray(40_000) { (it * 31 % 256).toByte() }
        val parts = formData {
            append("title", "holiday")
            append("tags", "sea, sun")
            append("photo", photo, Headers.build {
                append(HttpHeaders.ContentType, "image/png")
                append(HttpHeaders.ContentDisposition, "filename=\"beach.png\"")
            })
        }
        println(client.submitFormWithBinaryData("$base/upload", parts).bodyAsText())
        println(client.submitFormWithBinaryData("$base/fields", parts).bodyAsText())
        client.close()
    }
    server.stop(100, 1000)
}
