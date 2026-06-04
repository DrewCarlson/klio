fun main() {
    val a = byteArrayOf(1, 2, 3)
    val b = byteArrayOf(1, 2, 3)
    val c = byteArrayOf(1, 2, 4)
    println(a.contentEquals(b))
    println(a.contentEquals(c))
    println(a.contentEquals(byteArrayOf(1, 2)))

    println(intArrayOf(4, 5, 6).contentEquals(intArrayOf(4, 5, 6)))
    println(arrayOf("x", "y").contentEquals(arrayOf("x", "y")))
    println(arrayOf("x", "y").contentEquals(arrayOf("x", "z")))

    println(byteArrayOf(10, 20, 30).contentToString())
    println(intArrayOf(-1, 0, 1).contentToString())
    println(arrayOf("a", "b", "c").contentToString())
    println(intArrayOf().contentToString())
    println(doubleArrayOf(1.5, 2.5).contentToString())
}
