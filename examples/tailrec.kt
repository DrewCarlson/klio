tailrec fun factorial(n: Long, acc: Long = 1L): Long =
    if (n <= 1L) acc else factorial(n - 1L, acc * n)

tailrec fun sumDown(n: Int, acc: Int): Int = when {
    n == 0 -> acc
    else -> sumDown(n - 1, acc + n)
}

tailrec fun depth(n: Int): Int = if (n == 0) 0 else depth(n - 1)

fun main() {
    println(factorial(20L))
    println(sumDown(100, 0))
    println(depth(100000))
}
