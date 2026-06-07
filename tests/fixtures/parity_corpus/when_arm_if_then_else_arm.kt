// A when-arm body that is an `if (cond) expr` with no `else` must
// not swallow the following `else ->` when-arm. Upstream
// kotlinx-coroutines selects/Select.kt uses exactly this shape.
fun classify(x: Int): Int {
    when (x) {
        1 -> if (x > 0) return 11
        2 -> if (x < 0) return 22
        else -> return 99
    }
    return 0
}

fun main() {
    println(classify(1))
    println(classify(2))
    println(classify(5))
    // ordinary if/else unaffected
    val s = if (classify(1) == 11) "ok" else "no"
    println(s)
}
