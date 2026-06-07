fun main() {
    val words = listOf("apple","banana","cherry","avocado","blueberry","date")
    println(words.groupingBy { it.first() }.eachCount())
    println(listOf(1,2,3,4,5,6).groupingBy { it % 3 }.eachCount())
    println(words.groupingBy { it.first() }.fold(0) { acc, w -> acc + w.length })
    println(listOf("a","bb","a","bb","bb").groupingBy { it }.eachCount())
    println(listOf(1,2,3,4).groupingBy { it % 2 }.reduce { _, acc, e -> acc + e })
}
