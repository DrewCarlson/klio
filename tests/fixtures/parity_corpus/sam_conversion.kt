// SAM conversion via `fun interface`. A single-abstract-method
// interface can be constructed from a lambda using the
// `Interface { lambda }` form. The synthesized instance dispatches
// the abstract method through the lambda body.

fun interface IntPredicate {
    fun test(x: Int): Boolean
}

fun interface IntTransform {
    fun apply(x: Int): Int
}

fun main() {
    val isEven = IntPredicate { x -> x % 2 == 0 }
    println(isEven.test(4))
    println(isEven.test(5))

    val triple = IntTransform { x -> x * 3 }
    println(triple.apply(7))
    println(triple.apply(0))

    val composed = IntTransform { x -> x + 1 }
    println(composed.apply(triple.apply(10)))
}
