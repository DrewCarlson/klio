fun main() {
    val a = arrayOf(1, 2, 3)
    println(a.elementAt(0))
    println(a.elementAt(2))
    println((a + 4).joinToString(","))
    println((a + arrayOf(5, 6)).joinToString(","))
    println((a + listOf(7, 8)).joinToString(","))
    println(a.plus(9).joinToString(","))
    println(a.plusElement(10).joinToString(","))

    val ia = intArrayOf(10, 20, 30)
    println(ia.elementAt(1))
    println((ia + 40).joinToString(","))
    println((ia + intArrayOf(50)).joinToString(","))

    val ba = byteArrayOf(1, 2)
    println(ba.elementAt(0))

    val sa = arrayOf("a", "b")
    println((sa + "c").joinToString(","))
}
