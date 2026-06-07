// A line that begins with the elvis operator continues the previous
// expression — in an expression-body function and in a statement.
fun firstOrNull(xs: List<Int>): Int? = if (xs.isEmpty()) null else xs[0]

fun pick(xs: List<Int>): Int =
    firstOrNull(xs)
        ?: -1

fun main() {
    println(pick(listOf(7, 8)))
    println(pick(listOf()))
    val name: String? = null
    val shown = name
        ?: "anonymous"
    println(shown)
}
