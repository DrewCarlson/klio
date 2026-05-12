fun main() {
    val xs = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(xs.sortedWith(naturalOrder<Int>()))
    println(xs.sortedWith(reverseOrder<Int>()))
    val ws = listOf("pear", "apple", "kiwi")
    println(ws.sortedWith(naturalOrder<String>()))
    println(ws.sortedWith(reverseOrder<String>()))
}
