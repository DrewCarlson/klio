// The remaining HTTP verbs on HttpClient (ktor-client-core), mirroring
// get/post: a simple `verb(url)` and a `verbWith(url) { … }` builder DSL.

package io.ktor.client

import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpMethod

private suspend fun HttpClient.verb(method: HttpMethod, url: String, body: String): HttpResponse {
    val b = HttpRequestBuilder()
    b.method = method
    b.url = url
    b.body = body
    return request(b)
}

private suspend fun HttpClient.verbWith(
    method: HttpMethod,
    url: String,
    configure: HttpRequestBuilder.() -> Unit,
): HttpResponse {
    val b = HttpRequestBuilder()
    b.method = method
    b.url = url
    b.configure()
    return request(b)
}

suspend fun HttpClient.put(url: String, body: String = ""): HttpResponse = verb(HttpMethod.Put, url, body)
suspend fun HttpClient.delete(url: String, body: String = ""): HttpResponse = verb(HttpMethod.Delete, url, body)
suspend fun HttpClient.patch(url: String, body: String = ""): HttpResponse = verb(HttpMethod.Patch, url, body)
suspend fun HttpClient.head(url: String): HttpResponse = verb(HttpMethod.Head, url, "")
suspend fun HttpClient.options(url: String): HttpResponse = verb(HttpMethod.Options, url, "")

suspend fun HttpClient.putWith(url: String, configure: HttpRequestBuilder.() -> Unit): HttpResponse =
    verbWith(HttpMethod.Put, url, configure)
suspend fun HttpClient.deleteWith(url: String, configure: HttpRequestBuilder.() -> Unit): HttpResponse =
    verbWith(HttpMethod.Delete, url, configure)
suspend fun HttpClient.patchWith(url: String, configure: HttpRequestBuilder.() -> Unit): HttpResponse =
    verbWith(HttpMethod.Patch, url, configure)
