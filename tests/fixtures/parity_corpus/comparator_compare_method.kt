fun main() {
    val byLen = compareBy<String> { it.length }
    println(byLen.compare("a", "bb"))
    println(byLen.compare("bb", "a"))
    println(byLen.compare("xx", "yy"))

    val rev = byLen.reversed()
    println(rev.compare("a", "bb"))

    val byLenThenAlpha = compareBy<String> { it.length }.thenBy { it }
    println(byLenThenAlpha.compare("ab", "ba"))
    println(byLenThenAlpha.compare("ba", "ab"))
    println(byLenThenAlpha.compare("ab", "ab"))

    val nat = naturalOrder<Int>()
    println(nat.compare(1, 2))
    println(nat.compare(5, 5))
    println(reverseOrder<Int>().compare(1, 2))
}
