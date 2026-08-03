abstract class Holder<T : Iterable<String>>(val data: T) {
    fun countF(): Int = data.count { it.startsWith("f") }
    fun shout(): List<String> = data.map { it.uppercase() }
}

class ListHolder(xs: List<String>) : Holder<List<String>>(xs)

fun main() {
    val h = ListHolder(listOf("foo", "bar", "fizz"))
    println(h.countF())
    println(h.shout())
}
