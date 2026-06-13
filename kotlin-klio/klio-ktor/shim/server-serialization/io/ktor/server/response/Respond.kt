// Klio shim: typed server responses backed by kotlinx-serialization.
// Serializes the value to a JSON response body.

package io.ktor.server.response

import io.ktor.server.application.ApplicationCall
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToString

inline fun <reified T> ApplicationCall.respond(value: T) {
    this.responseBody = Json.encodeToString(value)
    this.responseContentType = "application/json"
}
