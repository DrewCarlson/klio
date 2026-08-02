class CustomException(message: String) : Exception(message) {
    override fun toString(): String = "CustomException: $message"
}

fun <T> describe(r: Result<T>): String = r.toString()

fun main() {
    val fail = Result.failure<Unit>(CustomException("F"))
    println(fail)
    println("tpl: $fail")
    println(describe(fail))
    println(fail.isFailure)
    println(fail.exceptionOrNull())
    val ok = Result.success("OK")
    println(describe(ok))
    val rc = runCatching { throw CustomException("G") }
    println(rc)
}
