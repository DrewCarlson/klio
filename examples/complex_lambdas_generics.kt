// Deeply nested lambdas/closures, currying, function composition,
// memoization via a captured map, a generic recursive Tree with
// fold/map, and tail-recursive accumulation.

tailrec fun sumTo(n: Int, acc: Long = 0): Long =
    if (n == 0) acc else sumTo(n - 1, acc + n)

fun <A, B, C> compose(f: (B) -> C, g: (A) -> B): (A) -> C = { a -> f(g(a)) }

fun <A, B, C> curry(f: (A, B) -> C): (A) -> (B) -> C = { a -> { b -> f(a, b) } }

fun memoize(f: (Int) -> Long): (Int) -> Long {
    val cache = HashMap<Int, Long>()
    return { n -> cache.getOrPut(n) { f(n) } }
}

sealed interface Tree<out T> {
    data class Leaf<T>(val value: T) : Tree<T>
    data class Branch<T>(val left: Tree<T>, val right: Tree<T>) : Tree<T>
}

fun <T, R> Tree<T>.fold(onLeaf: (T) -> R, merge: (R, R) -> R): R = when (this) {
    is Tree.Leaf -> onLeaf(value)
    is Tree.Branch -> merge(left.fold(onLeaf, merge), right.fold(onLeaf, merge))
}

fun <T, R> Tree<T>.map(f: (T) -> R): Tree<R> = when (this) {
    is Tree.Leaf -> Tree.Leaf(f(value))
    is Tree.Branch -> Tree.Branch(left.map(f), right.map(f))
}

fun main() {
    // Three-deep lambda nest: a function returning a function that
    // closes over a builder lambda which itself closes over `base`.
    val adderFactory: (Int) -> (Int) -> ((Int) -> Int) = { base ->
        { step ->
            { x -> base + step * x }
        }
    }
    val f = adderFactory(100)(5)
    println(listOf(0, 1, 2, 3).map(f))

    val inc: (Int) -> Int = { it + 1 }
    val dbl: (Int) -> Int = { it * 2 }
    val incThenDbl = compose(dbl, inc)
    val dblThenInc = compose(inc, dbl)
    println("${incThenDbl(10)} ${dblThenInc(10)}")

    val add = curry { a: Int, b: Int -> a + b }
    val add10 = add(10)
    println("${add10(5)} ${add(3)(4)}")

    // Memoized recursive Fibonacci: the recursive reference is
    // resolved through a captured `lateinit`-style holder.
    lateinit var fib: (Int) -> Long
    fib = memoize { n -> if (n < 2) n.toLong() else fib(n - 1) + fib(n - 2) }
    println((0..15).map { fib(it) })

    val tree: Tree<Int> = Tree.Branch(
        Tree.Branch(Tree.Leaf(1), Tree.Leaf(2)),
        Tree.Branch(Tree.Leaf(3), Tree.Branch(Tree.Leaf(4), Tree.Leaf(5)))
    )
    val sum = tree.fold({ it }, { a, b -> a + b })
    val depth = tree.fold({ _ -> 1 }, { a, b -> maxOf(a, b) + 1 })
    val doubled = tree.map { it * 2 }.fold({ "$it" }, { a, b -> "($a $b)" })
    println("sum=$sum depth=$depth shape=$doubled")

    // Tail-recursive accumulation, plus a fold producing a lambda
    // pipeline.
    println(sumTo(1_000))

    val pipeline: (Int) -> Int = listOf<(Int) -> Int>(
        { it + 3 }, { it * 4 }, { it - 1 }
    ).fold({ x: Int -> x }) { acc, stage -> { x -> stage(acc(x)) } }
    println(pipeline(2))

    // Lambda capturing a mutable var mutated across iterations,
    // then read after the loop (closure-over-mutable correctness).
    var total = 0
    val record: (Int) -> Unit = { total += it }
    (1..5).forEach(record)
    println("total=$total")

    // Generic higher-order: zipWith via nested lambdas.
    fun <A, B, C> List<A>.zipWith(other: List<B>, f: (A, B) -> C): List<C> =
        indices.map { i -> f(this[i], other[i]) }
    println(listOf(1, 2, 3).zipWith(listOf("a", "b", "c")) { n, s -> "$s$n" })
}
