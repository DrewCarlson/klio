// Klio shim for ktor server application types.
//
// `ApplicationCall` carries a request's method/path/body and collects
// the handler's response (status, content type, body) so the engine can
// write it back. `Application` holds the route table and the
// content-negotiation flag assembled by the module lambda.

package io.ktor.server.application

class ApplicationCall(
    val httpMethod: String,
    val uri: String,
    val requestBody: String,
) {
    var responseStatus: Int = 200
    var responseContentType: String = "text/plain"
    var responseBody: String = ""
}

class Application {
    var routing: io.ktor.server.routing.Routing? = null
    var jsonNegotiation: Boolean = false
}
