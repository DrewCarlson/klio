// Klio shim for the ContentNegotiation server plugin. Rather than redefine
// `respond`/`receive` (which would conflict with the core upstream
// declarations), it hooks the real send/receive pipelines:
//  - the send-side Render phase serializes a non-`OutgoingContent` body to a
//    JSON `TextContent`, so `respond(value)` flows through the engine's
//    `respondOutgoingContent` exactly like any other content;
//  - the receive-side Transform phase decodes a JSON request body into the
//    `call.receive<T>()` target type by its runtime class, so a typed
//    `receive<T>()` for a type the default transformers don't cover returns
//    the deserialized object.

package io.ktor.server.plugins.contentnegotiation

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.server.application.Application
import io.ktor.server.application.receiveType
import io.ktor.server.request.ApplicationReceivePipeline
import io.ktor.server.response.ApplicationSendPipeline
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readRemaining
import kotlinx.io.readByteArray
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeToClass

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
    receivePipeline.intercept(ApplicationReceivePipeline.Transform) { body ->
        if (body !is ByteReadChannel) return@intercept
        when (call.receiveType.type) {
            String::class,
            ByteArray::class,
            ByteReadChannel::class,
            Unit::class,
            HttpStatusCode::class -> return@intercept

            else -> {
                val text = body.readRemaining().readByteArray().decodeToString()
                val decoded = Json.decodeToClass(text, call.receiveType.type) ?: return@intercept
                proceedWith(decoded)
            }
        }
    }
}
