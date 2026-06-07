// numeric fidelity: Long (64-bit) wraps at i64::MAX boundary.

fun main() {
    val a = 9223372036854775807L
    println(a + 1L)
    val b = -9223372036854775807L - 1L
    println(b - 1L)
    println(a * 2L)
}
