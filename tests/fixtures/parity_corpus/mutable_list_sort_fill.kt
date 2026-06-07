fun main() {
    val a = mutableListOf(3, 1, 2, 5, 4)
    a.sortWith(compareByDescending { it })
    println(a)

    val words = mutableListOf("bb", "a", "cccc", "ddd")
    words.sortWith(compareBy { it.length })
    println(words)

    val tied = mutableListOf("zzz", "aa", "yy", "bbb")
    tied.sortWith(compareBy<String> { it.length }.thenByDescending { it })
    println(tied)

    val c = mutableListOf(1, 2, 3, 4)
    c.fill(7)
    println(c)
}
