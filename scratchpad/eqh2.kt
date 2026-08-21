class Box(val n: Int) {
    override fun equals(other: Any?): Boolean { return other is Box && other.n == n }
    override fun hashCode(): Int = n
    override fun toString(): String = "Box($n)"
}
fun main() {
    val xs = listOf(Box(1), Box(1), Box(2))
    println("contains = " + xs.contains(Box(1)))
    println("indexOf  = " + xs.indexOf(Box(2)))
    println("distinct = " + xs.distinct().size)
    println("toSet    = " + xs.toSet().size)
    println("distinctBy = " + xs.distinctBy { it }.size)
    println("union    = " + (xs union listOf(Box(1))).size)
    val seq = xs.asSequence().distinct().toList()
    println("seq dist = " + seq.size)
}
