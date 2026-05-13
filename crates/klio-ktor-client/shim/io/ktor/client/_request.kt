package io.ktor.client.request

import io.ktor.http.HttpMethod

class HttpRequestBuilder {
    var method: HttpMethod = HttpMethod.Get()
    var url: String = ""
    var body: String = ""
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
