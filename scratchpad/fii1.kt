interface Marker
class A(val v: String) : Marker
class B(val v: String) : Marker

fun main() {
    val xs: List<Any> = listOf(A("a1"), B("b1"), A("a2"))
    println("A = " + xs.filterIsInstance<A>().map { it.v })
    println("B = " + xs.filterIsInstance<B>().map { it.v })
    println("M = " + xs.filterIsInstance<Marker>().size)
}
