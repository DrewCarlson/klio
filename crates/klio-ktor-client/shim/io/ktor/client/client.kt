// Klio shim for `io.ktor.client.HttpClient`.
//
// The runtime is single-threaded, so request methods are blocking
// even though their upstream signature is `suspend`. Bodies execute
// on the calling thread via the native `__kktor_request` binding,
// which is backed by `ureq` in klio-ktor-client/src/lib.rs.

package io.ktor.client

import io.ktor.client.engine.__kktor_request
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpMethod

class HttpClient {
    fun close() {}

    suspend fun request(builder: HttpRequestBuilder): HttpResponse {
        if (builder.url.isEmpty()) {
            throw IllegalArgumentException("HttpRequestBuilder.url is empty")
        }
        val headers = builder.headers
        val flat = Array(headers.size * 2) { "" }
        var i = 0
        for ((k, v) in headers) {
            flat[i] = k; i += 1
            flat[i] = v; i += 1
        }
        val parts = __kktor_request(builder.method.value, builder.url, builder.body, flat)
        val status = parts[0].toInt()
        val body = parts[1]
        val ct = parts[2]
        val hmap = HashMap<String, String>()
        var j = 3
        while (j < parts.size - 1) {
            hmap[parts[j]] = parts[j + 1]
            j += 2
        }
        return HttpResponse(status, body, ct, hmap)
    }

    suspend fun get(url: String): HttpResponse {
        val b = HttpRequestBuilder()
        b.method = HttpMethod.Get()
        b.url = url
        return request(b)
    }

    suspend fun post(url: String, body: String): HttpResponse {
        val b = HttpRequestBuilder()
        b.method = HttpMethod.Post()
        b.url = url
        b.body = body
        return request(b)
    }
}

fun HttpClient(): HttpClient = HttpClient()
