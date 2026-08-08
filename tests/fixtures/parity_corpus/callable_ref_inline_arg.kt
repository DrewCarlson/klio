// A callable-reference argument of an INLINE callee must bind its target at
// lowering: `map(String::padWidth)` resolves the private extension in this
// file's own scope, and the invocation inside the spliced body calls it by
// fid — a name-carrying reference cannot reach a private extension at run
// time. The unbound-reference chain must also type end to end so the next
// call in the chain resolves statically.
private fun String.padWidth(): Int = length + 2

private fun StringBuilder.tag(): String = "<${toString()}>"

fun main() {
    val widths = listOf("a", "bb", "ccc").map(String::padWidth)
    println(widths)
    println(widths.sum())

    val refs = listOf(1, 2, 3).map(Int::toUInt)
    println(refs.sum())

    val sbs = listOf(StringBuilder("x"), StringBuilder("y")).map(StringBuilder::tag)
    println(sbs.joinToString(""))
}
