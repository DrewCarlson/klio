// Klio shim: plain-text server responses (server core, no serialization).

package io.ktor.server.response

import io.ktor.server.application.ApplicationCall

fun ApplicationCall.respondText(text: String) {
    this.responseBody = text
    this.responseContentType = "text/plain"
}
