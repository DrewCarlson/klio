class Pair2<out T>(val first: T, val second: T) {
    fun show(): String = first.toString() + "/" + second.toString()
    fun sameText(): Boolean = first.toString() == second.toString()
}

class Bag<E>(private val items: List<E>) {
    fun render(): String = items.joinToString(",") { it.toString() }
    fun hash(): Int { var h = 1; for (e in items) h = 31 * h + (e?.hashCode() ?: 0); return h }
}

fun <T : CharSequence> firstLen(xs: List<T>): Int = xs[0].length

fun <K, V> entryText(k: K, v: V): String = k.toString() + "=" + v.toString()

fun main() {
    println(Pair2(1, 2).show())
    println(Pair2("a", "a").sameText())
    println(Bag(listOf(3, 4)).render())
    println(Bag(listOf<String?>("x", null)).render())
    println(Bag(listOf(1, 2)).hash() != 0)
    println(firstLen(listOf("abc", "de")))
    println(entryText("k", 9))
}
