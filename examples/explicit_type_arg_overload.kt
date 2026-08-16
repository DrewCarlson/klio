// An explicit type-argument list is authoritative overload evidence: an
// empty list carries no element values, so `emptyList<Int>()` must bind the
// List<Int> overload statically — in every call order.
fun pick(xs: List<Int>): String = "pick(List<Int>)"
fun pick(xs: List<String>): String = "pick(List<String>)"

fun main() {
    println(pick(emptyList<String>()))
    println(pick(emptyList<Int>()))
    println(pick(listOf("a")))
    println(pick(listOf(1)))
}
