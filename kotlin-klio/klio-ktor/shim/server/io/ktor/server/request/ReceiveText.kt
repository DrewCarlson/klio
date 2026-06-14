// Klio shim: raw request body access (server core, no serialization).

package io.ktor.server.request

import io.ktor.server.application.ApplicationCall

fun ApplicationCall.receiveText(): String = this.request.bodyText
