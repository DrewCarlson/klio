// A block-body function with a non-Unit return type does not need
// an explicit `return` when its normal-completion path is
// unreachable (every path throws). Matches Kotlin's
// post-control-flow rule; klio defers T0005 to CFG reachability.
fun fail(msg: String): Int {
    throw IllegalStateException(msg)
}

fun pick(b: Boolean): Int {
    if (b) return 1
    throw RuntimeException("no")
}

fun main() {
    println(pick(true))
    try {
        fail("boom")
    } catch (e: IllegalStateException) {
        println("caught " + e.message)
    }
}
