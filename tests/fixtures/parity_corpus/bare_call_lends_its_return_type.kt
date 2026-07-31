// A bare call in a receiver context is a member of the implicit receiver
// written without `this.`, so it has a return type to lend a local it
// initialises. Measured, most locals whose initializer yields no type are a
// bare `iterator()` or `listIterator()` inside a stdlib extension body.
class Bag(private val items: List<String>) : Iterable<String> {
    override fun iterator(): Iterator<String> = items.iterator()
    fun size(): Int = items.size
}

fun Bag.firstTwo(): String {
    // `iterator()` is a bare call on the extension's own receiver; the local it
    // initialises is typed from its return type, so `hasNext`/`next` bind.
    val it = iterator()
    val sb = StringBuilder()
    if (it.hasNext()) sb.append(it.next())
    if (it.hasNext()) sb.append("/").append(it.next())
    return sb.toString()
}

fun Bag.countVia(): Int {
    val walker = iterator()
    var n = 0
    while (walker.hasNext()) {
        walker.next()
        n++
    }
    return n
}

fun List<String>.joinedBare(): String {
    val walker = listIterator()
    val sb = StringBuilder()
    while (walker.hasNext()) sb.append(walker.next())
    return sb.toString()
}

fun main() {
    val bag = Bag(listOf("a", "b", "c"))
    println(bag.firstTwo())
    println(bag.countVia())
    println(bag.size())
    println(listOf("x", "y").joinedBare())
}
