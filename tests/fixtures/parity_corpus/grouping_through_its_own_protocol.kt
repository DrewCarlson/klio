// A `Grouping` written in Kotlin must work through the interface's own
// protocol. klio builds its own representation for `groupingBy` — an instance
// carrying the source and the key selector — and the terminals read those
// fields directly, so an ordinary implementation of the interface was rejected
// with "expected a Grouping receiver". `groupingBy` is an inline extension
// returning `object : Grouping<T, K>`, so any call site that resolves it
// statically splices that body and produces exactly such an implementation.
class Words(private val items: List<String>) : Grouping<String, Char> {
    override fun sourceIterator(): Iterator<String> = items.iterator()
    override fun keyOf(element: String): Char = element.first()
}

fun main() {
    val g: Grouping<String, Char> = Words(listOf("foo", "bar", "flea", "zoo", "biscuit"))
    println(g.eachCount().toSortedMap())
    println(g.fold(0) { acc, e -> acc + e.length }.toSortedMap())
    println(g.reduce { _, acc, e -> if (e.length > acc.length) e else acc }.toSortedMap())

    // klio's own representation still works, and agrees.
    val direct = listOf("foo", "bar", "flea", "zoo", "biscuit").groupingBy { it.first() }
    println(direct.eachCount().toSortedMap())
    println(direct.fold(0) { acc, e -> acc + e.length }.toSortedMap())
}
