tailrec fun loop(n: Int): Int =
    if (n == 0) 0 else 1 + loop(n - 1)

fun main() {
    println(loop(3))
}
