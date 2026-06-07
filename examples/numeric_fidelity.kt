// Demonstrates M27 numeric type fidelity:
//   * Distinct runtime types for Int / Long / Short / Byte / Float / Double.
//   * 32-bit wraparound for Int; 64-bit for Long.
//   * Conversion methods preserve target-type semantics.
//   * Mixed-type promotion follows Kotlin rules.

fun main() {
    println(2147483647 + 1)
    println(9223372036854775807L + 1L)

    val n = 5
    println(n.toLong())
    println(n.toDouble())
    println(n.toByte().toInt())

    val l = 5000000000L
    println(l.toInt())

    val d = 1.7
    println(d.toInt())
    println(d.toFloat())

    println(1 + 1L)
    println(1L + 1.0)

    for (i in 1L..3L) {
        println(i)
    }
}
