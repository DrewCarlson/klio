// M27 numeric fidelity: Int (32-bit) wraps at i32::MAX boundary.

fun main() {
    val a = 2147483647
    println(a + 1)
    println(a + 2)
    val b = -2147483648
    println(b - 1)
    println(b * 2)
    println(a * 2)
}
