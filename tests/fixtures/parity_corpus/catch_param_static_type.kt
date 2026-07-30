// A catch parameter's declared type is static evidence for calls on it in the
// handler, and recording it must not change what those calls do.
//
// It did. `kotlin-klio/kotlin-internal/ThrowableActuals.kt` defined
// `Throwable.stackTraceToString()` as `this.toString()`, discarding frames,
// cause and suppressed. That placeholder was unreachable while receivers were
// untyped — klio's host renderer served instead — so typing the catch parameter
// made a stub implementation reachable for the first time and the trace lost
// its `Caused by:` chain while `cause` itself stayed correct.
class Boom(val detail: String) : RuntimeException(detail) {
    fun describe(): String = "boom:" + detail
}

fun main() {
    val e = try {
        try {
            throw IllegalStateException("Root cause")
        } catch (inner: Throwable) {
            inner.addSuppressed(UnsupportedOperationException("Side error"))
            throw RuntimeException("Induced", inner)
        }
    } catch (outer: Throwable) {
        outer.apply { addSuppressed(UnsupportedOperationException("Side two")) }
    }
    val trace = e.stackTraceToString()
    println("cause=" + (e.cause?.message ?: "NONE"))
    println("renders-cause=" + ("Root cause" in trace))
    println("renders-suppressed=" + ("Side error" in trace))
    println("renders-outer-suppressed=" + ("Side two" in trace))
    println("suppressed-count=" + e.suppressedExceptions.size)

    // The declared type binds member calls on the handler's binding.
    try {
        throw Boom("x")
    } catch (b: Boom) {
        println(b.describe())
    }
}
