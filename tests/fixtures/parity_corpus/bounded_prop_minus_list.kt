// The provenance flip's pinned shape: a class property typed by the class's
// own bounded parameter keeps the PARAMETER name, and the bound machinery
// resolves member and operator calls against the BOUND's static type —
// `data - arrayOf(...)` on `T : Iterable<String>` binds Iterable.minus and
// produces a LIST even when the runtime value is a Set, exactly as kotlinc
// compiles it.
abstract class Shelf<T : Iterable<String>>(val makeFrom: (Array<out String>) -> T) {
    fun makeFrom(vararg items: String): T = makeFrom(items)
    val data = makeFrom("foo", "bar")
    fun probeMinusArray(): Any = data - arrayOf("foo", "g")
    fun probeMinusElement(): Any = data - "foo"
    fun probeCount(): Int = data.count { it.startsWith("b") }
}

class SetShelf : Shelf<LinkedHashSet<String>>({ xs -> LinkedHashSet(xs.toList()) })

fun main() {
    val s = SetShelf()
    val a = s.probeMinusArray()
    val e = s.probeMinusElement()
    println(a)
    println(a is List<*>)
    println(e)
    println(e is List<*>)
    println(s.probeCount())
}
