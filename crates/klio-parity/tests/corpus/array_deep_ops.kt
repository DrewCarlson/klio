fun main() {
    println(arrayOf(1, 2, 3).orEmpty().size)
    println(arrayOf(arrayOf(1, 2), arrayOf(3, 4, 5)).contentDeepToString())
    println(arrayOf("a", arrayOf("b", "c")).contentDeepToString())
    println(arrayOf(intArrayOf(1, 2), intArrayOf(3)).contentDeepToString())
    println(arrayOf(arrayOf(1, 2)).contentDeepEquals(arrayOf(arrayOf(1, 2))))
    println(arrayOf(arrayOf(1, 2)).contentDeepEquals(arrayOf(arrayOf(1, 3))))
    println(arrayOf(arrayOf(1, 2), arrayOf(3)).contentDeepHashCode())
}
