class Named(val n: String) { fun tag(): String = "<$n>" }
class Holder(val items: List<Named>, val lookup: Map<String, Named>) {
    fun firstTag(): String = items[0].tag()
    fun loopTags(): String { val sb = StringBuilder(); for (i in items) sb.append(i.tag()); return sb.toString() }
    fun mapped(): String = items.map { it.tag() }.joinToString(",")
    fun viaMap(): String = lookup.values.first().tag()
}
val topItems: List<Named> = listOf(Named("t"))
fun topTag(): String = topItems[0].tag()
fun main() {
    val h = Holder(listOf(Named("a"), Named("b")), mapOf("k" to Named("c")))
    println(h.firstTag()); println(h.loopTags()); println(h.mapped()); println(h.viaMap()); println(topTag())
}
