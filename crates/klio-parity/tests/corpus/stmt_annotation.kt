// Annotations may precede a statement (not just a declaration):
// before a `val`, an expression statement, and a labeled `return`
// inside a lambda. They are runtime no-ops.
fun <T> wrap(block: () -> T): T = block()

fun compute(): Int = wrap {
    val base = 10
    @Suppress("UNCHECKED_CAST")
    return@wrap base + 5
}

fun main() {
    @Suppress("UNUSED")
    val x = 3
    val sb = StringBuilder()
    @Suppress("X")
    sb.append("hi")
    println(x)
    println(sb.toString())
    println(compute())
}
