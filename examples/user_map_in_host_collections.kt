// A class of the program's own that implements `Map` works wherever the
// library's collections take a map: copied into a `HashMap`, added with
// `putAll`, and compared with `==` from either side. One class declares its
// `entries`; the other gets every member by delegation and compares by its
// content, as kotlinx-serialization's `JsonObject` does.
//
// Run with: klio run examples/user_map_in_host_collections.kt

class Scores(private val content: Map<String, Int>) : AbstractMap<String, Int>() {
    override val entries: Set<Map.Entry<String, Int>> get() = content.entries
}

class Doc(private val content: Map<String, Int>) : Map<String, Int> by content {
    override fun equals(other: Any?): Boolean = content == other
    override fun hashCode(): Int = content.hashCode()
    override fun toString(): String = content.entries.joinToString(",", "{", "}") { (k, v) -> "\"$k\":$v" }
}

fun main() {
    val scores = Scores(mapOf("ann" to 3, "bob" to 5))
    println(HashMap(scores).entries.sortedBy { it.key })
    val merged = HashMap<String, Int>()
    merged["cy"] = 1
    merged.putAll(scores)
    println(merged.entries.sortedBy { it.key })
    println(mapOf("ann" to 3, "bob" to 5) == scores)
    println(scores == Scores(mapOf("bob" to 5, "ann" to 3)))
    println(scores == mapOf("ann" to 3))

    val doc = Doc(mapOf("key" to 42))
    val same = Doc(mapOf("key" to 42))
    println(doc)
    println(doc == same)
    println(doc == mapOf("key" to 42))
    println(mapOf("key" to 42) == doc)
    println(HashMap(doc).entries.sortedBy { it.key })
    println(listOf(doc) == listOf(same))
    println(doc.size + doc.getValue("key"))
}
