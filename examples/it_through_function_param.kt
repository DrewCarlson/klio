// A lambda argument's arity comes from the callee's declared type even when the
// callee is a function-typed PARAMETER rather than a named function: the value
// is the only place that type is written down. `block { … }` in a `() -> Unit`
// slot therefore declares no `it` of its own, so the `it` inside it is still the
// enclosing lambda's — the shape kotlinx-coroutines-test's `testResultMap` uses
// to hand a `Result` to the block it wraps.
fun chain(block: () -> Unit, after: (Result<Unit>) -> Unit) {
    try {
        block()
        after(Result.success(Unit))
    } catch (e: Throwable) {
        after(Result.failure(e))
    }
}

fun map(block: (() -> Unit) -> Unit, test: () -> Unit) = chain(
    block = test,
    after = {
        // `it` is `chain`'s Result, not an implicit parameter of this lambda.
        block { it.getOrThrow() }
        println("after ran")
    },
)

fun main() {
    map({ body -> body(); println("no throw") }, { println("test ran") })
    map(
        { body ->
            try {
                body()
            } catch (e: Throwable) {
                println("caught " + e.message)
            }
        },
        { throw RuntimeException("boom") },
    )

    // The same rule through a local val, and with the outer `it` named.
    val run1: (() -> Unit) -> Unit = { f -> f() }
    listOf("x").forEach { run1 { println("elem " + it) } }
    listOf("y").forEach { e -> run1 { println("elem " + e) } }
}
