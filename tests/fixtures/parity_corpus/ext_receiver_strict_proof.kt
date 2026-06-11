// The strict extension gate proves the declared receiver type against the
// actual receiver: a function-shape receiver needs a function value, a
// bounded type parameter needs the bound satisfied, generic arguments are
// checked against the elements the runtime value carries, a typealias
// expands, and a nullable receiver accepts a null subject. Inapplicable
// inner extensions never pre-empt an outer member.
class Outer {
    fun describe(): String = "outer-member"
    fun halve(): String = "outer-member"
    fun render(): String = "outer-member"
}
class Inner
class Thing

fun (() -> Int).describe(): String = "fn-ext"
fun <T : Number> T.halve(): String = "number-ext"
fun List<String>.render(): String = "string-list-ext"
typealias Rows = List<Int>
fun Rows.total(): String = "rows-ext"
fun Thing?.show(): String = if (this == null) "ext-null" else "ext-thing"

fun main() {
    with(Outer()) { with(Inner()) { println(describe()) } }
    with(Outer()) { with("str") { println(halve()) } }
    with(Outer()) { with(42) { println(halve()) } }
    with(Outer()) { with(listOf(1, 2)) { println(render()) } }
    with(Outer()) { with(listOf("a", "b")) { println(render()) } }
    with(Outer()) { with(listOf(1, 2)) { println(total()) } }
    val t: Thing? = null
    with(t) { println(show()) }
}
