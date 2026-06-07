fun <T> id(x: T): T = x
fun <T> first(a: T, b: T): T = a
fun <A, B> firstOf(a: A, b: B): A = a

fun main() {
    // Two id() calls inside first() — both inner T's and the outer
    // T are bound in the same session and resolve together.
    val n: Int = first(id(1), id(2))
    println(n)

    // Asymmetric: the outer has two type params, the inner one.
    // The session lets the outer pick A = String from id("a")'s
    // refined return while B = Int comes from id(3).
    val s: String = firstOf(id("a"), id(3))
    println(s)

    // Three-deep nesting.
    val k: Int = id(id(id(5)))
    println(k)
}
