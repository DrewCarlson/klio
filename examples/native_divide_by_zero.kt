// Kotlin THROWS on integer division by zero; C leaves it undefined. The
// compiled program raises a real throwable, so a `catch` sees it and an
// uncaught one is reported by the runtime — the one place that knows how a
// throwable reads.
fun safeDiv(a: Int, b: Int): Int {
    try {
        return a / b
    } catch (e: ArithmeticException) {
        return -1
    }
}

fun main() {
    println(safeDiv(10, 2))
    println(safeDiv(10, 0))
    println(safeDiv(7, 0))
}
