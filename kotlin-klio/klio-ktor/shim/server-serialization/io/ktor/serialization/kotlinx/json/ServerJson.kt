// `json()` registration for the server-side ContentNegotiation config,
// the server counterpart to the client `json()` extension. Overloaded by
// receiver type within the same `io.ktor.serialization.kotlinx.json`
// package users import.

package io.ktor.serialization.kotlinx.json

fun io.ktor.server.plugins.contentnegotiation.ContentNegotiationConfig.json() {
    registered.add("application/json")
}
