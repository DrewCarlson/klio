// Spec ch.9: `_` placeholder binds nothing. Visible here via a class
// that records each `componentN` call — `_` slots must not increment the
// call counter.
var componentCalls = 0

class Counted(val a: Int, val b: Int, val c: Int) {
    operator fun component1(): Int { componentCalls = componentCalls + 1; return a }
    operator fun component2(): Int { componentCalls = componentCalls + 1; return b }
    operator fun component3(): Int { componentCalls = componentCalls + 1; return c }
}

fun main() {
    val (x, _, z) = Counted(7, 8, 11)
    println(x)
    println(z)
    println(componentCalls)

    val pairs = listOf(1 to "a", 2 to "b", 3 to "c")
    for ((n, _) in pairs) println(n)
    for ((_, s) in pairs) println(s)
}
