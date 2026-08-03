// A nested lambda's `it` shadows the outer `it` for every static record:
// the inner receiver is the ELEMENT (String), so the local String extension
// binds — typing the inner `it` from the outer List record refuted it.
fun main() {
    fun String.nonEmptyLength() = if (isEmpty()) null else length
    listOf("", "sort", "abc").let {
        println(it.sortedBy { it.nonEmptyLength() })
        println(it.sortedByDescending { it.nonEmptyLength() })
        println(it.sortedWith(compareBy(nullsLast<Int>()) { it.nonEmptyLength() }))
    }
    // The spliced form: `all` inlines, its loop element types the `it`.
    println("  ".all { it.isWhitespace() })
    println("a b".all { it.isWhitespace() })
}
