// Klio shim for ktor server responses. `respond(value)` serializes the
// value to a JSON response body; `respondText` sends a plain string.

package io.ktor.server.response

import io.ktor.server.application.ApplicationCall
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToString

inline fun <reified T> ApplicationCall.respond(value: T) {
    this.responseBody = Json.encodeToString(value)
    this.responseContentType = "application/json"
}

fun ApplicationCall.respondText(text: String) {
    this.responseBody = text
    this.responseContentType = "text/plain"
}
