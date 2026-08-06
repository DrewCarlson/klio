class Wrap(val s: String) {
    fun tag(): String = "[$s]"
    fun width(): Int = s.length
}

private inline fun cutting(x: String, cut: (String) -> Wrap?): String =
    cut(x)?.let { it.tag() + it.width() } ?: "none"

private fun orNone(w: Wrap?): String = w?.let { it.tag() } ?: "none"

private fun applied(w: Wrap?): String = w?.apply { }?.tag() ?: "none"

fun main() {
    println(cutting("q") { Wrap("c$it") })
    println(cutting("q") { null })
    println(orNone(Wrap("d")))
    println(orNone(null))
    println(applied(Wrap("e")))
    println(applied(null))
    val chain: String? = "abc"
    println(chain?.let { it.substring(1) }?.uppercase() ?: "-")
}
