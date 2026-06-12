// klio's ContentNegotiation plugin for the upstream client core, built on
// the real plugin API (`createClientPlugin` + the transform hooks, the same
// surface HttpPlainText uses). JSON via kotlinx-serialization is the one
// converter klio ships, so `install(ContentNegotiation) { json() }` wires:
//  - request: a non-primitive `setBody(value)` serializes to a JSON
//    `TextContent` (the upstream default transformers keep handling
//    String/ByteArray/OutgoingContent bodies);
//  - response: a `body<T>()` request for a type the default transformers
//    don't cover decodes the body text into `T` by its runtime class.

package io.ktor.client.plugins.contentnegotiation

import io.ktor.client.plugins.api.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.http.content.*
import io.ktor.utils.io.*
import kotlinx.io.Source
import kotlinx.io.readByteArray
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.decodeToClass
import kotlinx.serialization.json.encodeValue

public class ContentNegotiationConfig {
    // Registered converter media types, for introspection. JSON is the only
    // format klio serializes.
    public val registered: MutableList<String> = mutableListOf()
}

public val ContentNegotiation: ClientPlugin<ContentNegotiationConfig> = createClientPlugin(
    "ContentNegotiation",
    ::ContentNegotiationConfig
) {
    transformRequestBody { request, content, bodyType ->
        when (content) {
            is String, is ByteArray, is OutgoingContent -> null
            else -> TextContent(Json.encodeValue(content), ContentType.Application.Json)
        }
    }

    transformResponseBody { response, content, requestedType ->
        when (requestedType.type) {
            String::class,
            ByteArray::class,
            Unit::class,
            Source::class,
            ByteReadChannel::class,
            HttpStatusCode::class -> null

            else -> {
                val text = content.readRemaining().readByteArray().decodeToString()
                Json.decodeToClass(text, requestedType.type)
            }
        }
    }
}
