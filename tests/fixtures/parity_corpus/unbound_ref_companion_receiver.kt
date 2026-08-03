fun main() {
    val numbers = List(5) { it }
    println(numbers.map(Int::toUInt))
    println(numbers.map(Int::toLong).sum())
    val words = listOf("a", "bb")
    println(words.map(String::length))
}
