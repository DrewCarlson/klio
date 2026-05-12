fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6, 7)
    println(xs.groupBy { it % 3 })
    println(xs.associate { it to it * it })
    println(xs.associateBy { it * 10 })
    println(xs.associateWith { it * it })
    println(xs.partition { it % 2 == 0 })
}
