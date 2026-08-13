fun fib(n: Int): Int {
    if (n < 2) return n
    return fib(n - 1) + fib(n - 2)
}

fun main() {
    var sum = 0
    var i = 0
    while (i < 10) {
        sum += i * i
        i++
    }
    println(sum)
    println(fib(20))
    val xs = listOf(3, 1, 2).sorted()
    println(xs.joinToString(","))
    try {
        val z = 10 / (i - 10)
        println(z)
    } catch (e: ArithmeticException) {
        println("caught: ${e.message}")
    }
}
