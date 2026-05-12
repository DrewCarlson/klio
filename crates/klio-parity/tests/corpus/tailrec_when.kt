tailrec fun classify(n: Int, acc: Int): Int = when {
    n == 0 -> acc
    n % 2 == 0 -> classify(n - 1, acc + 1)
    else -> classify(n - 1, acc + 2)
}

fun main() {
    println(classify(10, 0))
    println(classify(0, 100))
    println(classify(7, 0))
}
