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

class HttpClientConfig {
    var timeoutMillis: Long = 60_000L
    var connectTimeoutMillis: Long = -1L
    var tlsInsecure: Boolean = false
    // Set when `install(ContentNegotiation) { … }` runs. The typed
    // body helpers route through JSON regardless; this records the
    // registration so client setup matches ktor's shape.
    var contentNegotiation: io.ktor.client.plugins.contentnegotiation.ContentNegotiationConfig? = null
}

class HttpClient(val config: HttpClientConfig) {
    fun close() {}

    suspend fun request(builder: HttpRequestBuilder): HttpResponse {
        if (builder.url.isEmpty()) {
            throw IllegalArgumentException("HttpRequestBuilder.url is empty")
        }
        val headers = builder.headers
        // Prepend the per-client config knobs as reserved-key
        // headers; the engine strips them before sending.
        val configHeaders = HashMap<String, String>()
        configHeaders["__klio_cfg_timeout_ms"] = config.timeoutMillis.toString()
        if (config.connectTimeoutMillis >= 0L) {
            configHeaders["__klio_cfg_connect_timeout_ms"] = config.connectTimeoutMillis.toString()
        }
        if (config.tlsInsecure) {
            configHeaders["__klio_cfg_tls_insecure"] = "true"
        }
        val total = headers.size + configHeaders.size
        val flat = Array(total * 2) { "" }
        var i = 0
        for ((k, v) in configHeaders) {
            flat[i] = k; i += 1
            flat[i] = v; i += 1
        }
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
        // Engine may signal a binary body via the reserved
        // X-Klio-Body-Hex header; promote it onto bodyBytes when
        // present so downstream callers see the raw bytes.
        val rawHex = hmap["X-Klio-Body-Hex"]
        val rawBytes = if (rawHex != null) io.ktor.http.__kktor_hexToBytes(rawHex) else ByteArray(0)
        return HttpResponse(status, body, ct, hmap, rawBytes)
    }

    suspend fun get(url: String): HttpResponse {
        val b = HttpRequestBuilder()
        b.method = HttpMethod.Get
        b.url = url
        return request(b)
    }

    suspend fun post(url: String, body: String): HttpResponse {
        val b = HttpRequestBuilder()
        b.method = HttpMethod.Post
        b.url = url
        b.body = body
        return request(b)
    }
}

fun HttpClient(): HttpClient = HttpClient(HttpClientConfig())

fun HttpClient(configure: HttpClientConfig.() -> Unit): HttpClient {
    val cfg = HttpClientConfig()
    cfg.configure()
    return HttpClient(cfg)
}

// DSL form: `client.get(url) { header(...); accept(...) }`. The
// configure lambda runs against a fresh HttpRequestBuilder before
// the request is dispatched. Mirrors upstream ktor's builder DSL.

suspend fun HttpClient.getWith(
    url: String,
    configure: HttpRequestBuilder.() -> Unit,
): HttpResponse {
    val b = HttpRequestBuilder()
    b.method = HttpMethod.Get
    b.url = url
    b.configure()
    return request(b)
}

suspend fun HttpClient.postWith(
    url: String,
    configure: HttpRequestBuilder.() -> Unit,
): HttpResponse {
    val b = HttpRequestBuilder()
    b.method = HttpMethod.Post
    b.url = url
    b.configure()
    return request(b)
}

suspend fun HttpClient.requestWith(
    configure: HttpRequestBuilder.() -> Unit,
): HttpResponse {
    val b = HttpRequestBuilder()
    b.configure()
    return request(b)
}
