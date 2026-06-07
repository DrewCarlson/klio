fun main() {
    val xs = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(xs.asSequence().sorted().toList())
    println(xs.asSequence().sortedDescending().toList())

    val words = listOf("ccc", "a", "bb", "dddd")
    println(words.asSequence().sortedBy { it.length }.toList())
    println(words.asSequence().sortedByDescending { it.length }.toList())

    val cmp = compareBy<String> { it.length }.thenBy { it }
    println(words.asSequence().sortedWith(cmp).toList())

    // Generator + sort: bounded by `take`.
    println(generateSequence(1) { it + 1 }.take(5).sortedDescending().toList())
}
