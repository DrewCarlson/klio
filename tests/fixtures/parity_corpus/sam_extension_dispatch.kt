// A call on a SAM-converted `fun interface` instance whose name is NOT the
// interface's abstract method is a top-level extension on the SAM and must
// dispatch as such (with the SAM as receiver), not re-invoke the SAM
// lambda with the extension's args. Mirrors the stdlib `Comparator<T>`
// extensions (`reversed`, `thenBy`) used on a SAM-built comparator.
fun interface Cmp { fun compare(a: Int, b: Int): Int }

fun Cmp.label(): String = "cmp"
fun Cmp.flipped(): Cmp = Cmp { a, b -> this@flipped.compare(b, a) }

fun main() {
    val byVal = Cmp { a, b -> a - b }
    // abstract method -> invokes the lambda
    println(byVal.compare(1, 2))
    println(byVal.compare(5, 3))
    // extension that ignores the receiver
    println(byVal.label())
    // extension using this@ receiver inside its own SAM body
    val rev = byVal.flipped()
    println(rev.compare(1, 2))
    println(rev.compare(5, 3))
}
