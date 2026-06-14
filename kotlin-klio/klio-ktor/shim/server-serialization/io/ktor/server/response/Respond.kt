// Klio shim: typed server responses backed by kotlinx-serialization.
// Serializes the value to a JSON response body.

package io.ktor.server.response

import io.ktor.server.application.ApplicationCall
import io.ktor.http.HttpStatusCode
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToString

inline fun <reified T> ApplicationCall.respond(value: T) {
    this.response.body = Json.encodeToString(value)
    this.response.contentType = "application/json"
}

inline fun <reified T> ApplicationCall.respond(status: HttpStatusCode, value: T) {
    this.response.statusCode = status.value
    this.response.body = Json.encodeToString(value)
    this.response.contentType = "application/json"
}
