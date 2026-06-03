// Klio shim for ktor server request decoding. `receive<T>()` deserializes
// the request body from JSON into `T`.

package io.ktor.server.request

import io.ktor.server.application.ApplicationCall
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromString

inline fun <reified T> ApplicationCall.receive(): T =
    Json.decodeFromString<T>(this.requestBody)
