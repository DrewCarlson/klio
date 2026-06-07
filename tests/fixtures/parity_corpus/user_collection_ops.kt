// Stdlib collection operators on a user-defined collection: the builders
// (`ArrayList(coll)`, `toList`, `toSet`, `toMutableList`, `map`) accept a
// class implementing Collection by draining its iterator.
class Words(private val items: List<String>) : Collection<String> {
    override val size: Int get() = items.size
    override fun isEmpty(): Boolean = items.isEmpty()
    override fun contains(element: String): Boolean = items.contains(element)
    override fun containsAll(elements: Collection<String>): Boolean = items.containsAll(elements)
    override fun iterator(): Iterator<String> = items.iterator()
}

fun main() {
    val w = Words(listOf("beta", "alpha", "gamma"))
    println(w.toList())
    println(w.toMutableList().also { it.add("delta") })
    println(w.toSet().size)
    println(w.map { it.uppercase() })
    println(ArrayList(w))
    println(w.count())
    println(w.any { it.startsWith("a") })
    println(w.filter { it.length == 5 })
}
