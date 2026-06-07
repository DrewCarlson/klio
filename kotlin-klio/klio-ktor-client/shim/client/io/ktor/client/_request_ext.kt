// Request-builder conveniences (ktor-client-core): query parameters and
// authorization headers.

package io.ktor.client.request

import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

fun HttpRequestBuilder.parameter(name: String, value: String) {
    val sep = if (url.contains("?")) "&" else "?"
    url = url + sep + name + "=" + value
}

fun HttpRequestBuilder.bearerAuth(token: String) {
    headers["Authorization"] = "Bearer " + token
}

@OptIn(ExperimentalEncodingApi::class)
fun HttpRequestBuilder.basicAuth(username: String, password: String) {
    val token = Base64.encode("$username:$password".encodeToByteArray())
    headers["Authorization"] = "Basic " + token
}
