fun main() {
    val a = setOf(1, 2, 3, 4)
    val b = setOf(3, 4, 5, 6)
    println(a.union(b))
    println(a.intersect(b))
    println(a.subtract(b))
    println(a.plus(7))
    println(a.minus(2))
}
