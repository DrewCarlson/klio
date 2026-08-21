inline fun <reified T> nameOf(): String = T::class.simpleName ?: "?"

inline fun <reified U> checkIs(v: Any): Boolean = v is U

inline fun <reified T : Throwable> describe(cause: T): String {
    // A reified parameter used as the TYPE ARGUMENT of another reified call.
    val n = nameOf<T>()
    val ok = checkIs<T>(cause)
    return "$n/$ok"
}

fun main() {
    println(describe(IllegalStateException("x")))
    println(describe(IllegalArgumentException("y")))
    println(nameOf<String>())
}
