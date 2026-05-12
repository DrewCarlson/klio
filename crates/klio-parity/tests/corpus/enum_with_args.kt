enum class HttpStatus(val code: Int, val reason: String) {
    OK(200, "OK"),
    NOT_FOUND(404, "Not Found"),
    INTERNAL_ERROR(500, "Internal Server Error")
}

fun main() {
    for (s in HttpStatus.entries) {
        println("${s.name}: ${s.code} ${s.reason}")
    }
}
