// A throwable keeps at most the 1024 innermost frames of the stack it was
// made on, as the JVM keeps at most -XX:MaxJavaStackTraceDepth of them. A
// StackOverflowError's trace is the top of the stack that overflowed.
fun down(n: Int): Int = if (n == 0) throw IllegalStateException("bottom") else down(n - 1) + 1

fun runaway(n: Int): Int = runaway(n + 1) + 1

fun main(args: Array<String>) {
    try { down(3000) } catch (e: IllegalStateException) { println("deep " + e.stackTrace.size) }
    try { down(10) } catch (e: IllegalStateException) { println("shallow " + e.stackTrace.size) }
    try { runaway(0) } catch (e: StackOverflowError) {
        println("overflow " + e.stackTrace.size + " " + e.stackTrace[0].methodName)
    }
}
