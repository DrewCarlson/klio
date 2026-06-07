// Klio shim for the ContentNegotiation client plugin.
//
// The typed `body<T>()` / `setBody<T>()` helpers always route through
// kotlinx-serialization's JSON in klio, so installing the plugin and
// registering `json()` records the intent (and parses the idiomatic
// ktor setup block) without changing the wire format.

package io.ktor.client.plugins.contentnegotiation

import io.ktor.client.HttpClientConfig

class ContentNegotiationConfig {
    // The set of registered converters, by media type, for
    // introspection. JSON is the only format klio serializes.
    val registered: MutableList<String> = mutableListOf()
}

object ContentNegotiation

fun HttpClientConfig.install(
    plugin: ContentNegotiation,
    configure: ContentNegotiationConfig.() -> Unit,
) {
    val cfg = ContentNegotiationConfig()
    cfg.configure()
    contentNegotiation = cfg
}
