class Named(val n: String) { override fun toString(): String = "N($n)" }
class Boxed<E>(private val items: List<E>) {
    fun render(): String = items.joinToString(",") { it.toString() }
    fun hash(): Int { var h = 1; for (e in items) h = 31 * h + (e?.hashCode() ?: 0); return h }
}
fun <T> show(v: T): String = v.toString()
fun main() {
    println(Boxed(listOf(Named("a"), Named("b"))).render())
    println(Boxed(listOf<String?>("x", null)).render())
    println(show(Named("q")))
    println(show<String?>(null))
    println(Boxed(listOf(1, 2)).hash() != 0)
}
