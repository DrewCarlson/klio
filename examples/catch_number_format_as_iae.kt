// `NumberFormatException` is an `IllegalArgumentException`: a
// `catch (e: IllegalArgumentException)` around `toInt()` / `toDouble()` takes
// the host-thrown parse failure (kotlinx.serialization's `parseString` relies
// on exactly this), and the `is` checks agree with the declared hierarchy.
fun parseOr(text: String, fallback: Double): Double =
    try {
        text.toDouble()
    } catch (e: IllegalArgumentException) {
        println("caught ${e::class.simpleName} for '$text'")
        fallback
    }

fun main() {
    println(parseOr("1.5", 0.0))
    println(parseOr("1e-1e-1", -1.0))
    println(try { "abc".toInt() } catch (e: IllegalArgumentException) { "int fallback (${e::class.simpleName})" })
    val n = NumberFormatException("x")
    println("is IllegalArgumentException=${n is IllegalArgumentException} is RuntimeException=${n is RuntimeException} is Exception=${n is Exception}")
}
