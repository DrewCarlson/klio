fun main() {
    val words = listOf("banana", "apple", "cherry", "date")
    println(words.sortedWith(compareBy { it.length }))
    println(words.sortedWith(compareBy<String> { it.length }.thenBy { it }))
    println(words.sortedWith(compareByDescending { it.length }))
}
