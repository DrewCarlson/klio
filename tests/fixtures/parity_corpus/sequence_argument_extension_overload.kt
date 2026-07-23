private fun fibonacci(): Sequence<Int> =
    generateSequence(0 to 1) { it.second to it.first + it.second }
        .map { it.first }

fun main() {
    println(listOf(1) + fibonacci().take(4))
}
