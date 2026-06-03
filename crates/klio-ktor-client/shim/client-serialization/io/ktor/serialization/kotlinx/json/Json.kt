// Klio shim for `io.ktor.serialization.kotlinx.json.json()` — the
// content-negotiation registration users write as
// `install(ContentNegotiation) { json() }`.

package io.ktor.serialization.kotlinx.json

import io.ktor.client.plugins.contentnegotiation.ContentNegotiationConfig

fun ContentNegotiationConfig.json() {
    registered.add("application/json")
}
