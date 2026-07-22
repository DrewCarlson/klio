fun fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)

fun main() {
    val xs = (1..10).map { it * it }
    println("squares=$xs")
    println("sum=${xs.sum()}")
    println("fib10=${fib(10)}")
    val m = mapOf("a" to 1, "b" to 2)
    println("map=${m.entries.sortedBy { it.key }.joinToString { "${it.key}:${it.value}" }}")
    println("ok")
}
