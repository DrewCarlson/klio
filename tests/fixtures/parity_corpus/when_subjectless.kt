fun classify(n: Int): String = when {
    n < 0 -> "negative"
    n == 0 -> "zero"
    n < 10 -> "small"
    else -> "large"
}

fun main() {
    println(classify(-5))
    println(classify(0))
    println(classify(3))
    println(classify(99))
}
