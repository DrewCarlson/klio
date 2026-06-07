package io.ktor.client.request

import io.ktor.http.HttpMethod

class HttpRequestBuilder {
    var method: HttpMethod = HttpMethod.Get
    var url: String = ""
    var body: String = ""
    // Optional byte body. When non-empty, hex-encoded and shipped
    // through a reserved header so the engine can decode and use
    // it as the request payload regardless of UTF-8 validity.
    var bodyBytes: ByteArray? = null
    val headers: HashMap<String, String> = HashMap()

    fun header(name: String, value: String) {
        headers[name] = value
    }

    fun contentType(value: String) {
        headers["Content-Type"] = value
    }

    fun accept(value: String) {
        headers["Accept"] = value
    }
}
