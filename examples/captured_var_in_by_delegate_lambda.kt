// A `var` captured and mutated inside the lambda that builds a `by`-delegate
// must box (Kotlin `Ref` semantics): the lambda runs when the delegate is
// constructed, and its write has to land back on the enclosing `var`. The
// capture analysis has to look inside the delegate expression, not just a
// plain initializer, or the increment writes to a transient copy and the
// counter stays 0.

class Once(compute: () -> Int) {
    private val cached = compute()
    operator fun getValue(thisRef: Any?, property: Any?): Int = cached
}

fun main() {
    var invalidateCount = 0
    val answer by Once {
        invalidateCount++
        42
    }
    println(answer)
    println(answer)
    println("invalidateCount=$invalidateCount")
}
