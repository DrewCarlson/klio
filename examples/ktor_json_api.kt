// Run with: klio run --feature io.ktor/server-cio,server-content-negotiation,server-status-pages,server-default-headers,client-cio,client-content-negotiation,serialization-kotlinx-json examples/ktor_json_api.kt
// A small JSON API between the CIO server and the CIO client. Both sides use
// ContentNegotiation with kotlinx.serialization's JSON: the server receives
// and responds with @Serializable classes, StatusPages turns exceptions into
// JSON error bodies with the right status codes, and DefaultHeaders stamps
// every response. The client sends and receives the same classes.

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.request.delete
import io.ktor.client.request.get
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.install
import io.ktor.server.cio.CIO
import io.ktor.server.engine.applicationEnvironment
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.BadRequestException
import io.ktor.server.plugins.NotFoundException
import io.ktor.server.plugins.defaultheaders.DefaultHeaders
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.delete
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.util.logging.LogLevel
import io.ktor.util.logging.Logger
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.Serializable
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation as ClientContentNegotiation
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation as ServerContentNegotiation

@Serializable
data class Book(val id: Int, val title: String, val tags: List<String> = emptyList())

@Serializable
data class NewBook(val title: String, val tags: List<String> = emptyList())

@Serializable
data class ApiError(val status: Int, val message: String)

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
    val books = mutableMapOf(1 to Book(1, "Kotlin in Action", listOf("kotlin")))
    var nextId = 2

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
        install(ServerContentNegotiation) { json() }
        install(DefaultHeaders) { header("X-Api-Version", "1") }
        install(StatusPages) {
            exception<NotFoundException> { call, cause ->
                call.respond(HttpStatusCode.NotFound, ApiError(404, cause.message ?: "not found"))
            }
            exception<BadRequestException> { call, cause ->
                call.respond(HttpStatusCode.BadRequest, ApiError(400, cause.message ?: "bad request"))
            }
        }
        routing {
            route("/books") {
                get { call.respond(books.values.sortedBy { it.id }) }
                get("/{id}") {
                    val id = call.parameters["id"]?.toIntOrNull() ?: throw BadRequestException("id must be a number")
                    call.respond(books[id] ?: throw NotFoundException("no book $id"))
                }
                post {
                    val new = call.receive<NewBook>()
                    if (new.title.isBlank()) throw BadRequestException("title is empty")
                    val book = Book(nextId++, new.title, new.tags)
                    books[book.id] = book
                    call.respond(HttpStatusCode.Created, book)
                }
                delete("/{id}") {
                    val id = call.parameters["id"]!!.toInt()
                    books.remove(id) ?: throw NotFoundException("no book $id")
                    call.respond(HttpStatusCode.NoContent)
                }
            }
        }
    }.start(wait = false)

    runBlocking {
        val base = "http://127.0.0.1:${server.engine.resolvedConnectors().single().port}/books"
        val client = HttpClient(io.ktor.client.engine.cio.CIO) {
            install(ClientContentNegotiation) { json() }
        }

        val created = client.post(base) {
            contentType(ContentType.Application.Json)
            setBody(NewBook("Programming Kotlin", listOf("kotlin", "coroutines")))
        }
        println("${created.status.value} ${created.body<Book>()} api ${created.headers["X-Api-Version"]}")

        val all: List<Book> = client.get(base).body()
        println("all: ${all.map { it.title }}")

        val one = client.get("$base/2")
        println("json: ${one.bodyAsText()}")

        val missing = client.get("$base/9")
        println("${missing.status.value} ${missing.body<ApiError>()}")

        val bad = client.get("$base/abc")
        println("${bad.status.value} ${bad.body<ApiError>()}")

        val empty = client.post(base) {
            contentType(ContentType.Application.Json)
            setBody(NewBook(" "))
        }
        println("${empty.status.value} ${empty.body<ApiError>()}")

        println("delete: ${client.delete("$base/1").status.value}, then ${client.delete("$base/1").status.value}")
        client.close()
    }
    server.stop(100, 1000)
}
