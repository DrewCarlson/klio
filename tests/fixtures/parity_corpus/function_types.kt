fun apply(x: Int, f: (Int) -> Int): Int = f(x)

fun makeAdder(n: Int): (Int) -> Int = { v -> v + n }

fun main() {
    val doubler: (Int) -> Int = { x -> x * 2 }
    println(doubler(7))

    println(apply(20, { v -> v + 3 }))

    val nullable: ((Int) -> Int)? = null
    println(nullable)

    val plus5 = makeAdder(5)
    println(plus5(11))

    val curried: (Int) -> (Int) -> Int = { x -> { y -> x - y } }
    println(curried(10)(4))

    val pair: (Int, Int) -> Int = { a, b -> a * 100 + b }
    println(pair(2, 3))
}
