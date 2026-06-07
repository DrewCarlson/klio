fun main() {
    val words = listOf("ccc", "a", "bb", "dddd")
    val out = words
        .asSequence()
        .filter { it.length > 1 }
        .sortedBy { it.length }
        .map { it.uppercase() }
        .toList()
    println(out)

    val gen = generateSequence(1) { it + 1 }
        .take(5)
        .map { it * 10 }
        .filter { it > 20 }
        .toList()
    println(gen)

    val pairs = listOf("a" to 1, "b" to 2, "c" to 3)
        .filter { it.second > 1 }
        .associate { it }
    println(pairs)
}
