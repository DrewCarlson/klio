package io.ktor.client.statement

class HttpResponse(
    val status: Int,
    val bodyText: String,
    val contentType: String,
    val headers: HashMap<String, String>,
    // Optional raw body bytes (populated when the response body
    // was hex-encoded by the engine for binary safety).
    val bodyBytes: ByteArray = ByteArray(0),
) {
    fun isSuccess(): Boolean = status in 200..299
    suspend fun bodyAsText(): String = bodyText
    fun bodyAsBytes(): ByteArray {
        if (bodyBytes.isNotEmpty()) return bodyBytes
        val text = bodyText
        val out = ByteArray(text.length)
        for (i in 0 until text.length) {
            out[i] = (text[i].code and 0xff).toByte()
        }
        return out
    }
    override fun toString(): String = "HttpResponse(status=$status, ct=$contentType, body.length=${bodyText.length})"
}
