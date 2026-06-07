// Typed response body backed by kotlinx-serialization.
//
// `body<T>()` deserializes the response text into `T`. It is a reified
// inline extension — klio binds the reified type parameter for
// top-level / extension functions, and `decodeFromString<T>` forwards
// it on. With `ContentNegotiation` installed for JSON this mirrors
// ktor's `HttpResponse.body()`.

package io.ktor.client.call

import io.ktor.client.statement.HttpResponse
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeFromString

public inline fun <reified T> HttpResponse.body(): T =
    Json.decodeFromString<T>(this.bodyText)
