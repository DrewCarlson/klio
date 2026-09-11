// `try`/`catch` compiled to C. The handler stack and the in-flight value live
// in the emitted file rather than the runtime: `setjmp` has to be called in the
// frame that catches, so it cannot hide behind a function. A function that
// catches keeps its registers volatile, because a local written after `setjmp`
// and read after the jump back is otherwise indeterminate.
fun risky(n: Int): Int {
    if (n < 0) throw IllegalArgumentException("neg")
    if (n == 0) throw IllegalStateException("zero")
    return n * 2
}

fun guarded(n: Int): Int {
    try {
        return risky(n)
    } catch (e: IllegalArgumentException) {
        return -1
    }
}

fun main() {
    println(guarded(5))
    println(guarded(-1))

    // Thrown through one handler that does not match, caught by one that does.
    try {
        println(guarded(0))
    } catch (e: IllegalStateException) {
        println("outer caught")
    }

    // A region armed and left on every iteration.
    var total = 0
    var i = -2
    while (i < 3) {
        try {
            total = total + risky(i)
        } catch (e: Exception) {
            total = total + 100
        }
        i = i + 1
    }
    println(total)
    println("done")
}
