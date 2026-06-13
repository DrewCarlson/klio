// Klio shim for the ContentNegotiation server plugin. As on the client,
// `respond` / `receive` always route through kotlinx-serialization JSON,
// so installing the plugin records the registration and lets the
// idiomatic setup block parse.

package io.ktor.server.plugins.contentnegotiation

import io.ktor.server.application.Application

class ContentNegotiationConfig {
    val registered: MutableList<String> = mutableListOf()
}

object ContentNegotiation

fun Application.install(
    plugin: ContentNegotiation,
    configure: ContentNegotiationConfig.() -> Unit,
) {
    val cfg = ContentNegotiationConfig()
    cfg.configure()
    this.jsonNegotiation = true
}
