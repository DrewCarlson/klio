// Klio shim for ktor-client core types.

package io.ktor.http

class HttpMethod(val value: String) {
    override fun toString(): String = value
    override fun equals(other: Any?): Boolean = (other is HttpMethod) && other.value == value
    override fun hashCode(): Int = value.hashCode()

    // klio's pack loader builds companion objects eagerly during the
    // outer class's shell pass — so `val Get: HttpMethod =
    // HttpMethod("GET")` inside a companion would fire before the
    // outer class is bound. Function form is initialised lazily.
    companion object {
        fun Get(): HttpMethod = HttpMethod("GET")
        fun Post(): HttpMethod = HttpMethod("POST")
        fun Put(): HttpMethod = HttpMethod("PUT")
        fun Delete(): HttpMethod = HttpMethod("DELETE")
        fun Patch(): HttpMethod = HttpMethod("PATCH")
        fun Head(): HttpMethod = HttpMethod("HEAD")
        fun Options(): HttpMethod = HttpMethod("OPTIONS")
    }
}
