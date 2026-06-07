tailrec fun fib(n: Int, a: Long = 0, b: Long = 1): Long =
    if (n == 0) a else fib(n - 1, b, a + b)

fun main() {
    println(fib(30))
}
