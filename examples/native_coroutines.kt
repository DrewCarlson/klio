// Coroutines compiled to C. A `suspend` body becomes a state machine over a
// HEAP frame: it can return in the middle of itself and be re-entered later, so
// nothing may sit in a C local that the return would discard. A suspending call
// answers either its result or the SUSPENDED marker; a frame that sees SUSPENDED
// records its own continuation and answers SUSPENDED in turn, which builds the
// suspension innermost-first as the C stack unwinds.
//
// The driver is the interpreter's own — the scheduler, the virtual clock, the
// Job graph, the park and resume order. A compiled program presents its own
// host to it rather than getting a second scheduler, so both order their
// coroutines identically.
import kotlinx.coroutines.*

suspend fun tick(n: Int): Int {
    delay(10)
    return n + 1
}

suspend fun total(): Int {
    var s = 0
    s = s + tick(1)
    s = s + tick(2)
    s = s + tick(3)
    return s
}

suspend fun nested(n: Int): Int {
    val a = tick(n)
    val b = tick(a)
    return a + b
}

fun main() {
    runBlocking {
        println(total())
        println(nested(5))
        // A suspend function that never actually suspends still compiles as
        // one: whether it parks is a run-time answer.
        println(tick(0))
    }
}
