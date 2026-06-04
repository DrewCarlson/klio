// sorted / toTypedArray on a user-defined collection: the platform `expect`
// (toTypedArray) is a no-op stub, so dispatch must drain the receiver and run
// the intrinsic actual.
class Nums(private val items: List<Int>) : Collection<Int> {
    override val size: Int get() = items.size
    override fun isEmpty(): Boolean = items.isEmpty()
    override fun contains(element: Int): Boolean = items.contains(element)
    override fun containsAll(elements: Collection<Int>): Boolean = items.containsAll(elements)
    override fun iterator(): Iterator<Int> = items.iterator()
}
fun main() {
    val n = Nums(listOf(3, 1, 2))
    println(n.sorted())
    println(n.sortedDescending())
    println(n.toTypedArray().size)
    println(n.toTypedArray().joinToString("-"))
    println(n.max())
    println(n.sum())
}
