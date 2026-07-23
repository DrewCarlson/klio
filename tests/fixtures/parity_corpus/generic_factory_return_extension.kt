private fun <T : Comparable<T>> choose(a: T, b: T): T =
    arrayOf(a, b).minOrNull()!!

fun main() {
    println(choose(0.0, Double.NaN))
}
