package io.ktor.client.statement

class HttpResponse(
    val status: Int,
    val bodyText: String,
    val contentType: String,
    val headers: HashMap<String, String>,
) {
    fun isSuccess(): Boolean = status in 200..299
    suspend fun bodyAsText(): String = bodyText
    override fun toString(): String = "HttpResponse(status=$status, ct=$contentType, body.length=${bodyText.length})"
}
