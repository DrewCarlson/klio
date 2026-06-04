// Request-builder conveniences (ktor-client-core): query parameters and
// bearer auth. `basicAuth` needs Base64 and is added once that lands.

package io.ktor.client.request

fun HttpRequestBuilder.parameter(name: String, value: String) {
    val sep = if (url.contains("?")) "&" else "?"
    url = url + sep + name + "=" + value
}

fun HttpRequestBuilder.bearerAuth(token: String) {
    headers["Authorization"] = "Bearer " + token
}
