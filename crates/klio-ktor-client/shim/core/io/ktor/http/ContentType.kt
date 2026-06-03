// Klio shim for `io.ktor.http.ContentType`.

package io.ktor.http

class ContentType(val contentType: String, val contentSubtype: String) {
    fun withParameter(name: String, value: String): ContentType = this
    override fun toString(): String = "$contentType/$contentSubtype"
    override fun equals(other: Any?): Boolean =
        other is ContentType &&
            other.contentType == contentType &&
            other.contentSubtype == contentSubtype
    override fun hashCode(): Int = toString().hashCode()

    object Application {
        val Json: ContentType = ContentType("application", "json")
        val OctetStream: ContentType = ContentType("application", "octet-stream")
        val FormUrlEncoded: ContentType = ContentType("application", "x-www-form-urlencoded")
    }

    object Text {
        val Plain: ContentType = ContentType("text", "plain")
        val Html: ContentType = ContentType("text", "html")
    }
}
