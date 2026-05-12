fun even(n: Int): Boolean = if (n == 0) true else odd(n - 1)
fun odd(n: Int): Boolean = if (n == 0) false else even(n - 1)

fun main() {
    println(even(10))
}
