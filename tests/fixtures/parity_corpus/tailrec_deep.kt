tailrec fun loop(n: Int, acc: Int): Int =
    if (n == 0) acc else loop(n - 1, acc + 1)

fun main() {
    println(loop(100000, 0))
}
