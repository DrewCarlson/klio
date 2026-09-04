// A user class that shares its simple name with a library class keeps its
// own property types, and the library class keeps its own: `demo.Regex`
// declares `pattern: Int` while `kotlin.text.Regex.pattern` is a `String`,
// and a read through either type binds the overload for THAT class's
// property, never the other's.

package demo

class Regex(val pattern: Int) {
    fun describe() = "user regex level $pattern"
}

fun show(x: Int) = "int $x"
fun show(x: String) = "string $x"

fun sizeOf(r: kotlin.text.Regex) = show(r.pattern)

fun main() {
    val mine = Regex(2)
    println(mine.describe())
    println(show(mine.pattern))
    println(sizeOf(kotlin.text.Regex("a+b")))
    val stdlib: kotlin.text.Regex = "x?".toRegex()
    println(show(stdlib.pattern))
    println(show(stdlib.pattern.length))
}
