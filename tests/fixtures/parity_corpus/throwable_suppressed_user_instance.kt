package p

// `addSuppressed`/`suppressedExceptions` on a user-defined throwable class:
// the suppressed set is shared across aliases and survives throw/catch.

class MyError(message: String) : RuntimeException(message)

fun main() {
    val e = MyError("boom")
    println(e.suppressedExceptions.size)
    e.addSuppressed(IllegalStateException("side"))
    e.addSuppressed(MyError("side2"))
    println(e.suppressedExceptions.size)
    println(e.suppressedExceptions.map { it.message })
    val caught = try { throw e } catch (t: Throwable) { t }
    println(caught.suppressedExceptions.size)
}
