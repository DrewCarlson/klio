// Overloaded extension functions resolve by the runtime receiver
// type, not declaration order. A `fun Int.f()` that delegates via
// `toLong().f()` must reach `fun Long.f()` and terminate (this
// previously recursed into the Int overload forever).
fun Long.kind(): String = "Long"
fun Int.kind(): String = "Int"

fun Int.describe(level: Int): String =
    if (level <= 0) "Int($this)" else this.toLong().describe(level)
fun Long.describe(level: Int): String = "Long($this)"

fun main() {
    println(7.kind())
    println(7L.kind())
    println((1).describe(0))
    println((1).describe(3))
    println(2_000_000_000.toLong().kind())
}
