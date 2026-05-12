// M22: function types written as type annotations parse and round-trip
// through the AST. Lambdas assigned to function-typed `val`s, passed as
// parameters, and curried through nested function types all dispatch
// through the same invocation path that drives untyped lambdas.

fun apply(x: Int, f: (Int) -> Int): Int = f(x)

fun main() {
    val doubler: (Int) -> Int = { x -> x * 2 }
    println(doubler(5))
    println(apply(10, { v -> v + 1 }))

    val g: ((Int) -> Int)? = null
    println(g)

    val h: (Int) -> (Int) -> Int = { x -> { y -> x + y } }
    println(h(3)(4))

    val combine: (Int, Int) -> Int = { a, b -> a * 10 + b }
    println(combine(2, 3))
}
