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

fun interface IntCombiner {
    fun combine(left: Int, right: Int): Int
}

fun interface DefaultCombiner {
    fun combine(left: Int, middle: Int = 3, right: Int): Int
}

fun acceptsPredicate(predicate: IntPredicate): Boolean = predicate.test(8)

fun namedCombine(combiner: IntCombiner): Int = combiner.combine(right = 2, left = 10)

fun namedDefaultCombine(combiner: DefaultCombiner): Int = combiner.combine(right = 2, left = 10)

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

    val subtract: IntCombiner = IntCombiner { left, right -> left - right }
    println(subtract.combine(right = 2, left = 10))
    println(namedCombine { left, right -> left - right })

    val weighted: DefaultCombiner = DefaultCombiner { left, middle, right -> left + middle * 10 + right }
    println(weighted.combine(right = 2, left = 10))
    println(namedDefaultCombine { left, middle, right -> left + middle * 10 + right })
}
