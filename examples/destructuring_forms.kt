// Kotlin 2.4 destructuring. The positional short form `[a, b]` reads
// `componentN` exactly as `(a, b)` does; the name-based full form
// `(val a, val b)` reads properties by name, and `val n = prop` renames.
// Both work in declarations, `for` loops, and lambda parameters, and a
// `var` entry makes the binding mutable.
data class Point(val x: Int, val y: Int)
data class Entry(val key: String, val count: Int)

fun main() {
    val [a, b] = Point(1, 2)
    println("$a $b")
    (val y, val x) = Point(3, 4)
    println("$x $y")
    (val n = x, val m: Int = y) = Point(5, 6)
    println("$n $m")
    val entries = listOf(Entry("a", 1), Entry("b", 2))
    val positional = mutableListOf<String>()
    for ([k, c] in entries) positional.add("$k=$c")
    println(positional)
    val named = mutableListOf<String>()
    for ((val count, val key) in entries) named.add("$key:$count")
    println(named)
    println(entries.map { [k, c] -> "$k$c" })
    println(entries.map { (val key, val count) -> "$count$key" })
    println(entries.sumOf { (val total: Int = count) -> total })
    val indexed = mutableListOf<String>()
    for ([i, e] in entries.withIndex()) indexed.add("$i${e.key}")
    println(indexed)
    var [p, _] = Point(7, 8)
    p += 1
    println(p)
}
