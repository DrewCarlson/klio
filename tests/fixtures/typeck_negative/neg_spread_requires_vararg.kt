fun add(a: Int, b: Int): Int = a + b

fun main() {
    val xs = IntArray(2) { it + 1 }
    println(add(*xs))
}
