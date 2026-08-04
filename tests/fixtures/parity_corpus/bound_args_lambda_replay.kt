fun CharSequence.mark(): String = "cs"
fun String.mark(): String = "str"

fun <T> runBlock(block: () -> T): T = block()

abstract class Holder<T : Iterable<CharSequence>>(val data: T) {
    fun marks(): String = runBlock { data.joinToString(",") { it.mark() } }
    fun countA(): Int = runBlock { data.count { it.mark() == "cs" } }
}

class ListHolder(xs: List<CharSequence>) : Holder<List<CharSequence>>(xs)

fun main() {
    val h = ListHolder(listOf("a", "b"))
    println(h.marks())
    println(h.countA())
}
