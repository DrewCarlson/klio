class Box(val n: Int) {
    override fun equals(other: Any?): Boolean { return other is Box && other.n == n }
    override fun hashCode(): Int = n
}
fun main() {
    val xs: List<Box> = listOf(Box(1), Box(1), Box(2))
    val it: Iterable<Box> = xs
    println("list.distinct  = " + xs.distinct().size)
    println("iter.distinct  = " + it.distinct().size)
    val ms = xs.toMutableSet()
    println("toMutableSet   = " + ms.size)
    val hs = HashSet<Box>()
    hs.addAll(xs)
    println("HashSet.addAll = " + hs.size)
    val ls = LinkedHashSet<Box>()
    for (b in xs) ls.add(b)
    println("LinkedHashSet  = " + ls.size)
}
