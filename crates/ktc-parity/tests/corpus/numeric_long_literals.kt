// M27 numeric fidelity: Long literals.
//
// `1L`, `0xFFL`, and arithmetic between Longs stay 64-bit and surface as
// `kotlin.Long` at runtime so `is Long` answers correctly.

fun main() {
    val a = 1L
    val b = 0xFFL
    val c = 0b1010L
    println(a + b + c)
    println(a is Long)
    println(a is Int)
    println(b is Long)
    println(1L + 2L)
    println(100L * 200L)
    println(1000000000L * 1000000000L)
}
