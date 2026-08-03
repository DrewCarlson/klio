// A bare call inside an extension declared ON A FUNCTION TYPE must bind the
// same-file private inline function, never defer to a runtime member walk of
// the fn-typed receiver (whose only members are invoke/call). The private
// callee is declared AFTER its caller, and a class elsewhere declares members
// of both names to pollute the program-wide name sets.
class Distraction {
    fun runIt(tag: String) = println("member runIt($tag)")
    fun step() = println("member step")
}

fun <T> (() -> T).launchIt(tag: String): Unit = runIt(tag) {
    val r = this()
    println("ran $tag -> $r")
}

private inline fun runIt(tag: String, step: () -> Unit) {
    try {
        step()
    } catch (e: Throwable) {
        println("caught for $tag: $e")
    }
}

fun main() {
    val f = { 21 * 2 }
    f.launchIt("alpha")
    ({ "beta-value" }).launchIt("beta")
    Distraction().runIt("direct")
}
