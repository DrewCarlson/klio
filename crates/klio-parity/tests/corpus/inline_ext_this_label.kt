// `this@label` inside the lambda/SAM body of an inline extension binds to
// the extension receiver (the inline splice's `this`), not a class-chain
// walk or the enclosing call's receiver. This is the mechanism stdlib
// `Comparator<T>.thenBy { ... this@thenBy.compare(a, b) ... }` relies on.
class Adder(val base: Int) {
    fun apply(x: Int): Int = base + x
}

inline fun Adder.thenScale(crossinline factor: () -> Int): (Int) -> Int = { x ->
    this@thenScale.apply(x) * factor()
}

fun main() {
    val f = Adder(10).thenScale { 3 }
    println(f(1))   // (10 + 1) * 3 = 33
    println(f(5))   // (10 + 5) * 3 = 45
    val g = Adder(100).thenScale { 2 }
    println(g(0))   // 100 * 2 = 200
    println(listOf(1, 2, 3).map(f))
}
