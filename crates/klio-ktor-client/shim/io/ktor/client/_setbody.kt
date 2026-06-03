// Typed request body backed by kotlinx-serialization.
//
// `setBody(value)` serializes the value to a JSON request payload and
// marks the content type. `encodeToString` reflects over the value's
// runtime shape, so the reified parameter need not be bound. Mirrors
// ktor's `HttpRequestBuilder.setBody` with JSON content negotiation.

package io.ktor.client.request

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.encodeToString

public inline fun <reified T> HttpRequestBuilder.setBody(value: T) {
    this.body = Json.encodeToString(value)
    this.headers["Content-Type"] = "application/json"
}
