tailrec fun factorial(n: Long, acc: Long = 1L): Long =
    if (n <= 1L) acc else factorial(n - 1L, acc * n)

fun main() {
    println(factorial(0L))
    println(factorial(1L))
    println(factorial(5L))
    println(factorial(10L))
    println(factorial(20L))
}
