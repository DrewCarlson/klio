// Kotlin dispatches `a == b` on the LEFT operand: a native collection's
// equals is the collection CONTRACT (same size, equal elements), so
// `setOf(1) == MySet([1])` is true even though MySet never overrides
// equals -- while `MySet([1]) == setOf(1)` stays identity-false. The
// same holds nested inside a Pair.

class MySet(val items: List<Int>) : Set<Int> {
    override val size: Int get() = items.size
    override fun isEmpty(): Boolean = items.isEmpty()
    override fun contains(element: Int): Boolean = items.contains(element)
    override fun containsAll(elements: Collection<Int>): Boolean = elements.all { contains(it) }
    override fun iterator(): Iterator<Int> = items.iterator()
}

class MyList(val items: List<Int>) : List<Int> by items

fun main() {
    val native = setOf(1)
    val wrapped: Set<Int> = MySet(listOf(1))
    println(native == wrapped)
    println(wrapped == native)
    println((native to "x") == (wrapped to "x"))
    println(setOf(1, 2) == MySet(listOf(1)))
    println(listOf(3, 4) == MyList(listOf(3, 4)))
    println(listOf(3) == MyList(listOf(3, 4)))
}
