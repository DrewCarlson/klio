fun main() {
    // Laziness: onEach + filter + first() must pull only until the first match,
    // not run the whole source.
    var count = 0
    val r = generateSequence(1) { it + 1 }
        .onEach { count++ }
        .filter { it % 2 == 0 }
        .first()
    println(r)
    println(count)

    // first(predicate) short-circuits over a huge range.
    var c2 = 0
    val found = (1..1_000_000).asSequence().onEach { c2++ }.first { it > 5 }
    println(found)
    println(c2)

    // map.take(n) is lazy (only n upstream evaluations).
    var c3 = 0
    val taken = generateSequence(1) { it + 1 }
        .onEach { c3++ }
        .map { it * it }
        .take(3)
        .toList()
    println(taken)
    println(c3)

    // mapIndexed / filterIndexed
    println(listOf("a", "b", "c", "d").asSequence().mapIndexed { i, v -> "$i$v" }.toList())
    println((10..20).asSequence().filterIndexed { i, _ -> i % 2 == 0 }.toList())

    // any / none / find / firstOrNull short-circuit
    println((1..1_000_000).asSequence().any { it > 3 })
    println((1..5).asSequence().none { it > 100 })
    println(sequenceOf(1, 2, 3, 4).find { it % 2 == 0 })
    println(sequenceOf(1, 2, 3).firstOrNull { it > 9 })

    // onEach is also lazy as an intermediate (no terminal pull => nothing runs)
    var c4 = 0
    generateSequence(1) { it + 1 }.onEach { c4++ }.take(0).toList()
    println(c4)
}
