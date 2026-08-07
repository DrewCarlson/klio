class Named(val n: String) { fun tag(): String = "<$n>" }

class Holder(val items: List<Named>, val lookup: Map<String, Named>) {
    fun byIndexCall(): String = items.get(0).tag()
    fun byKeyCall(): String = lookup.get("k")?.tag() ?: "-"
    fun byIndexOperator(): String = items[0].tag()
    fun byKeyOperator(): String = lookup["k"]?.tag() ?: "-"
    fun viaLast(): String = items.last().tag()
}

fun main() {
    val h = Holder(listOf(Named("a"), Named("b")), mapOf("k" to Named("c")))
    println(h.byIndexCall())
    println(h.byKeyCall())
    println(h.byIndexOperator())
    println(h.byKeyOperator())
    println(h.viaLast())
    println(Holder(listOf(), mapOf()).byKeyCall())
}
