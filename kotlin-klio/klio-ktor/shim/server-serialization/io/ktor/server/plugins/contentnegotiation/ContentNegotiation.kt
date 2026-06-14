// Klio shim for the ContentNegotiation server plugin. Rather than redefine
// `respond`/`receive` (which would conflict with the core upstream
// declarations), it hooks the real send/receive pipelines: the send-side
// Render phase serializes a non-`OutgoingContent` body to a JSON
// `TextContent`, so the upstream `respond(value)` flows through the engine's
// `respondOutgoingContent` exactly like any other content.

package io.ktor.server.plugins.contentnegotiation

import io.ktor.http.ContentType
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.server.application.Application
import io.ktor.server.response.ApplicationSendPipeline
import kotlinx.serialization.json.Json

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
    sendPipeline.intercept(ApplicationSendPipeline.Render) { value ->
        if (value is OutgoingContent || value is String) return@intercept
        val json = Json.encodeToString(value)
        proceedWith(TextContent(json, ContentType.Application.Json))
    }
}
