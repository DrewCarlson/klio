fun main() {
    val xs = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(xs.sorted())
    println(xs.sortedDescending())
    println(xs.reversed())
    println(xs.distinct())

    val words = listOf("banana", "apple", "cherry")
    println(words.sorted())
    println(words.sortedBy { it.length })
    println(words.sortedByDescending { it.length })
    println(words.distinctBy { it.length })
}
