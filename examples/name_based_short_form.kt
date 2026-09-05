// Run with: klio run --language=+EnableNameBasedDestructuringShortForm examples/name_based_short_form.kt
// With the short form enabled, a parenthesized destructuring `(a, b = prop)`
// binds by property name instead of by position: `(second)` reads
// `second`, `(text = title)` renames, and `(_ = counted)` still reads the
// property for its effect. The bracket form `[a, b]` stays positional.
data class Tuple(val first: String, val second: Int)

object Counter {
    var reads = 0
    val counted: Int
        get() = ++reads
}

fun main() {
    val x = Tuple("OK", 1)
    val (second) = x
    println(second)
    val (b = second, a = first) = x
    println("$a $b")
    val (n: Int = second, s: String = first) = x
    println("$s $n")
    val [p, q] = x
    println("$p $q")
    for ((first, second) in listOf(x)) println("$first$second")
    for ((second: Int) in arrayOf(x)) println(second)
    println(listOf(x).map { (second, first) -> "$first-$second" })
    val (_ = counted) = Counter
    for ((_ = counted) in listOf(Counter)) {}
    println(Counter.reads)
}
