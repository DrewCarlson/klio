fun describe(x: Int): String = when (x) {
    0 -> "zero"
    1, 2 -> "small"
    in 3..9 -> "medium"
    else -> "big"
}

fun main() {
    println(describe(0))
    println(describe(1))
    println(describe(2))
    println(describe(5))
    println(describe(100))
}
