fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6).asSequence()
    println(xs.groupBy { it % 2 })
    println(xs.associate { it to it * it })
    println(xs.associateBy { it * 10 })
    println(xs.associateWith { it * 10 })
    println(xs.partition { it > 3 })
}
