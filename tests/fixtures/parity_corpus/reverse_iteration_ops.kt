fun main() {
    println(listOf(1, 2, 3).foldRight(0) { v, acc -> acc + v })
    println(listOf("a", "b", "c").foldRight("") { v, acc -> acc + v })
    println(listOf(1, 2, 3, 4).reduceRight { v, acc -> v - acc })
    println(emptyList<Int>().reduceRightOrNull { a, b -> a + b })
    println(listOf(10, 20, 30, 40).last { it < 35 })
    println(listOf(1, 2, 3).last())
    println(listOf(1, 2, 3).lastOrNull { it > 5 })
    println(listOf(2, 4, 6).findLast { it % 4 == 0 })
    println(setOf(5, 10, 15).last())
    println(mutableListOf(3, 1, 2).last { it < 3 })
}
