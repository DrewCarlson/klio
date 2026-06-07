// `@JvmInline value class` (and plain `value class`) gets a
// compiler-synthesised structural equals/hashCode/toString over its
// single backing property — like a one-component data class, but no
// copy(). Identity is value-based, so set dedup collapses equals.
@JvmInline
value class Meters(val v: Long)

value class Tag(val s: String)

fun main() {
    val a = Meters(5)
    val b = Meters(5)
    val c = Meters(9)
    println(a == b)
    println(a == c)
    println(a.hashCode() == b.hashCode())
    println(a)
    val s = setOf(Meters(1), Meters(1), Meters(2))
    println(s.size)
    println(Tag("x") == Tag("x"))
    println(Tag("x") == Tag("y"))
    println(Tag("hi"))
}
