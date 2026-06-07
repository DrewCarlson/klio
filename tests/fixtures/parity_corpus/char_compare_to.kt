fun main() {
    println('a'.compareTo('b'))
    println('c'.compareTo('a'))
    println('m'.compareTo('m'))

    // Sorting by a Char key (the case that used to hang on Char.compareTo).
    println(listOf("bx", "az", "by", "aa").sortedWith(compareBy { it[0] }))
    println(listOf('c', 'a', 'b').sortedWith(compareByDescending { it }))
    val m = mutableListOf("delta", "alpha", "charlie", "bravo")
    m.sortWith(compareBy { it[0] })
    println(m)
}
