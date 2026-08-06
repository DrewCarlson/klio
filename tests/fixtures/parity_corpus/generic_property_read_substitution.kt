class Named(val n: String) { fun tag(): String = "<$n>" }

class Holder(val lookup: Map<String, Named>, val rows: List<List<Named>>) {
    fun loop(): String { val sb = StringBuilder(); for (v in lookup.values) sb.append(v.tag()); return sb.toString() }
    fun mapped(): String = lookup.values.map { it.tag() }.joinToString(",")
    fun keyLens(): String = lookup.keys.map { it.length }.joinToString(",")
    fun nested(): String {
        val sb = StringBuilder()
        for (row in rows) for (c in row) sb.append(c.tag())
        return sb.toString()
    }
}

fun main() {
    val h = Holder(mapOf("k" to Named("c"), "kk" to Named("d")), listOf(listOf(Named("x")), listOf(Named("y"))))
    println(h.loop())
    println(h.mapped())
    println(h.keyLens())
    println(h.nested())
}
