// M26: SAM conversion via `fun interface`. A single-abstract-method
// interface can be constructed from a lambda using the
// `Interface { lambda }` form. The synthesized instance dispatches
// the abstract method through the lambda body.

fun interface IntPredicate {
    fun test(x: Int): Boolean
}

fun interface IntTransform {
    fun apply(x: Int): Int
}

fun acceptsPredicate(predicate: IntPredicate): Boolean = predicate.test(8)

fun main() {
    val isEven: IntPredicate = IntPredicate { x -> x % 2 == 0 }
    println(isEven.test(4))
    println(isEven.test(5))

    val triple: IntTransform = IntTransform { x -> x * 3 }
    println(triple.apply(7))
    println(triple.apply(0))

    val composed: IntTransform = IntTransform { x -> x + 1 }
    println(composed.apply(triple.apply(10)))

    println(acceptsPredicate { x -> x == 8 })
}
