// A `break` or `continue` inside a lambda passed to an inline function targets
// the loop enclosing the CALL SITE, not a loop inside the inline function: the
// lambda is written in the caller, so its jumps are the caller's.

inline fun <T> Iterable<T>.each(action: (T) -> Unit) {
    for (element in this) action(element)
}

fun main() {
    // `break` exits the outer loop, even though `each` has its own inner loop.
    val stopped = mutableListOf<Int>()
    for (i in 1..3) {
        (1..3).each { j ->
            if (j == 3) break
            stopped += i * 10 + j
        }
    }
    println("break: $stopped")

    // `continue` skips to the next outer iteration.
    val skipped = mutableListOf<Int>()
    for (i in 1..3) {
        (1..2).each { j ->
            if (i == 2) continue
            skipped += i * 10 + j
        }
    }
    println("continue: $skipped")
}
