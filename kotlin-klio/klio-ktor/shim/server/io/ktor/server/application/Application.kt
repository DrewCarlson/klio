// Klio shim for ktor server application types.
//
// `ApplicationCall` carries the request (method, uri, headers, query and
// path parameters, body) and collects the handler's response (status,
// content type, body, headers) so the engine can write it back.
// `Application` holds the route table and the content-negotiation flag
// assembled by the module lambda.

package io.ktor.server.application

import io.ktor.http.HttpStatusCode

// Case-insensitive request header lookup, matching ktor's `Headers`. Keys
// are stored lowercased by the engine.
class Headers(private val entries: Map<String, String>) {
    operator fun get(name: String): String? = entries[name.lowercase()]
    fun contains(name: String): Boolean = entries.containsKey(name.lowercase())
}

class ApplicationRequest(
    val httpMethod: String,
    // The raw request target, including any `?query` (matching `call.request.uri`).
    val uri: String,
    val headers: Headers,
    // `?key=value` pairs, accessed like `call.request.queryParameters["q"]`.
    val queryParameters: Map<String, String>,
    val bodyText: String,
)

// Collected response headers; `call.response.headers.append(name, value)`.
class ResponseHeaders {
    val entries: ArrayList<Pair<String, String>> = ArrayList()
    fun append(name: String, value: String) {
        entries.add(name to value)
    }
}

class ApplicationResponse {
    val headers: ResponseHeaders = ResponseHeaders()
    var statusCode: Int = 200
    var contentType: String = "text/plain"
    var body: String = ""

    fun status(code: HttpStatusCode) {
        statusCode = code.value
    }
}

class ApplicationCall(
    val request: ApplicationRequest,
    // Path parameters captured from a `{name}` route segment.
    val parameters: Map<String, String>,
) {
    val response: ApplicationResponse = ApplicationResponse()

    // Convenience accessor for the raw request body (see also `receiveText()`).
    val requestBody: String get() = request.bodyText
}

class Application {
    var routing: io.ktor.server.routing.Routing? = null
    var jsonNegotiation: Boolean = false
}
