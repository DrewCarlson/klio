// Inside `apply { … }` the receiver is the lambda's erased type parameter, so
// whether it carries a name is unknowable where the call lowers. A pick made
// there is a guess, and typing the call by that declaration's return poisons
// every call chained after it: `drop(1)` typed as a CharSequence made the
// `forEach` beside it the CharSequence one, which then iterated a List through
// `length`. An unproven pick names no type, and the chain dispatches on the
// value it actually has — the shape kotlinx-coroutines-test's `throwAll` uses.
fun main() {
    val errs: List<Throwable> = listOf(RuntimeException("x"), RuntimeException("y"), RuntimeException("z"))
    with(errs) {
        firstOrNull()?.apply {
            drop(1).forEach { println("suppressed " + it.message) }
            println("head " + message)
        }
    }

    // The receiver that genuinely IS a CharSequence still picks the CharSequence
    // overload: the rule declines a guess, it does not decline a known type.
    with(listOf("abc")) {
        firstOrNull()?.apply {
            println("chars " + drop(1).count())
        }
    }

    val nested: List<List<Int>> = listOf(listOf(1, 2, 3))
    with(nested) {
        firstOrNull()?.apply {
            println("tail sum " + drop(1).sum())
        }
    }
}
