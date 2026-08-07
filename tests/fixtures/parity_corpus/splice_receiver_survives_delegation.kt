class Named(val n: String) { fun tag(): String = "<$n>" }

class Holder(val lookup: Map<String, Named>, val items: List<Named>) {
    fun mappedValues(): String = lookup.values.map { it.tag() }.joinToString(",")
    fun mappedItems(): String = items.map { it.tag() }.joinToString(",")
    fun keyLens(): String = lookup.keys.map { it.length }.joinToString(",")
    fun filtered(): String = lookup.values.filter { it.tag().isNotEmpty() }.map { it.tag() }.joinToString(",")
}

fun main() {
    val h = Holder(mapOf("k" to Named("c"), "kk" to Named("d")), listOf(Named("a"), Named("b")))
    println(h.mappedValues())
    println(h.mappedItems())
    println(h.keyLens())
    println(h.filtered())
}
