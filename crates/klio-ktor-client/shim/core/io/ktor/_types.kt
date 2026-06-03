// Klio shim for ktor-client core types.

package io.ktor.http

class HttpMethod(val value: String) {
    override fun toString(): String = value
    override fun equals(other: Any?): Boolean = (other is HttpMethod) && other.value == value
    override fun hashCode(): Int = value.hashCode()

    companion object {
        val Get: HttpMethod = HttpMethod("GET")
        val Post: HttpMethod = HttpMethod("POST")
        val Put: HttpMethod = HttpMethod("PUT")
        val Delete: HttpMethod = HttpMethod("DELETE")
        val Patch: HttpMethod = HttpMethod("PATCH")
        val Head: HttpMethod = HttpMethod("HEAD")
        val Options: HttpMethod = HttpMethod("OPTIONS")
    }
}
