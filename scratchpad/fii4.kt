class A(val v: String)
class B(val v: String)

fun main() {
    val xs: List<Any> = listOf(A("a"), B("b"))
    println("P1 = " + xs.filterIsInstance<A>().size)
    println("Q1 = " + xs.filterIsInstance<B>().size)
    println("P2 = " + xs.filterIsInstance<A>().size)
    val f = { l: List<Any> -> l.filterIsInstance<A>().size }
    val g = { l: List<Any> -> l.filterIsInstance<B>().size }
    println("f/g = " + f(xs) + "/" + g(xs))
}
