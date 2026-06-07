fun main() {
    val items = listOf(
        "a" to 3,
        "b" to 1,
        "a" to 1,
        "b" to 3,
        "a" to 2,
    )
    println(items.sortedWith(compareBy<Pair<String, Int>> { it.first }.thenByDescending { it.second }))
    println(items.sortedWith(compareByDescending<Pair<String, Int>> { it.first }.thenBy { it.second }))
}
