fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    println(xs.map { it * 2 })
    println(xs.filter { it > 2 })
    println(xs.filterNot { it > 2 })
    println(xs.any { it > 4 })
    println(xs.all { it > 0 })
    println(xs.none { it > 5 })
    println(xs.count { it % 2 == 0 })
    println(xs.find { it > 3 })
    println(xs.sumOf { it })
    println(xs.fold(0) { acc, x -> acc + x })
    println(xs.reduce { acc, x -> acc * x })
    xs.forEach { println(it) }
}
