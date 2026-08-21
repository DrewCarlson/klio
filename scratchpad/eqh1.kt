class Box(val n: Int) {
    override fun equals(other: Any?): Boolean = other is Box && other.n == n
    override fun hashCode(): Int = n
    override fun toString(): String = "Box($n)"
}

class Plain(val n: Int)

data class D(val n: Int)

fun main() {
    val xs = listOf(Box(1), Box(1), Box(2))
    println("list     = " + xs)
    println("distinct = " + xs.distinct())
    println("set      = " + xs.toSet())
    println("contains = " + xs.toSet().contains(Box(1)))
    println("eq       = " + (Box(1) == Box(1)))
    println("map      = " + mapOf(Box(1) to "a")[Box(1)])

    val ds = listOf(D(1), D(1), D(2))
    println("data dis = " + ds.distinct())
    println("group    = " + xs.groupBy { it }.size)
}
