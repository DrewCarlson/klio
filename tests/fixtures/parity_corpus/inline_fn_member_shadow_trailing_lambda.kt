// A call carrying a trailing lambda must bind the arity-matching inline fn,
// not a lower-arity same-named member that would silently drop the lambda and
// recurse. `make(value)` (the 1-arg member) sits beside the top-level 2-arg
// `inline fun make(value, init)`; `make(value) { … }` resolves to the inline
// fn because the member's arity can't accept the lambda. This is ktor's
// `ContentDisposition.Companion.parse(value) = parse(value) { v, p -> … }`
// shape (its `parse` inherits the 2-arg `HeaderValueWithParameters.parse`).
class Tag(val name: String, val width: Int = 0) {
    override fun toString(): String = "$name/$width"

    companion object {
        fun make(value: String): Tag = make(value) { v, n -> Tag(v, n) }
    }
}

inline fun <R> make(value: String, init: (String, Int) -> R): R {
    val trimmed = value.trim()
    return init(trimmed, trimmed.length)
}

fun main() {
    println(Tag.make("box"))
    println(Tag.make("  wrapper  "))
    println(Tag.make("x"))
}
