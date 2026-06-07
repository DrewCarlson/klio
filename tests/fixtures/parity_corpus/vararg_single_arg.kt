fun <T> wrap(vararg xs: T): List<T> = xs.toList()

fun main() {
    println(mutableListOf("z"))
    println(mutableListOf("a", "b"))
    println(mutableListOf<String>())
    println(wrap("only"))
    println(wrap(1, 2, 3))
    val m = mutableListOf("c")
    m.add("d")
    println(m)
}
