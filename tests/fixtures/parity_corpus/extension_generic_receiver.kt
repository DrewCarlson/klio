fun <T> List<T>.second(): T = this[1]

fun <K, V> Map<K, V>.firstKey(): K = this.keys.first()

fun main() {
    val xs = listOf("a", "b", "c")
    println(xs.second())

    val ys = listOf(10, 20, 30)
    println(ys.second())
}
