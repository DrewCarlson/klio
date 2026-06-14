// Klio shim: plain-text server responses (server core, no serialization).

package io.ktor.server.response

import io.ktor.server.application.ApplicationCall
import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode

fun ApplicationCall.respondText(
    text: String,
    contentType: ContentType? = null,
    status: HttpStatusCode? = null,
) {
    this.response.body = text
    this.response.contentType = (contentType ?: ContentType.Text.Plain).toString()
    if (status != null) this.response.statusCode = status.value
}
