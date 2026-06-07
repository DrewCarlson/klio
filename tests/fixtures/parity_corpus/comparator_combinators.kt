fun main() {
    println(compareValues(1, 2))
    println(compareValues(2, 1))
    println(compareValues(1, 1))
    println(compareValues(null, 1))
    println(compareValues(1, null))

    println(compareValuesBy("a", "bb") { it.length })
    println(compareValuesBy("ab", "ba", { it.length }, { it }))
    println(compareValuesBy("xx", "xx", { it.length }, { it }))

    val byLen = compareBy<String> { it.length }
    val byAlpha = compareBy<String> { it }
    val combo = byLen.then(byAlpha)
    println(combo.compare("ab", "ba"))
    println(combo.compare("ba", "ab"))
    println(combo.compare("aaa", "bb"))

    val rev = byLen.thenDescending(byAlpha)
    println(rev.compare("ab", "ba"))
    println(rev.compare("ba", "ab"))

    val tc = byLen.thenComparator { a, b -> a.compareTo(b) }
    println(tc.compare("ab", "ba"))
}
