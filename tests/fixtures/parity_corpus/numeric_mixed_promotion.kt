// numeric fidelity: mixed-type arithmetic follows Kotlin promotion
// rules.

fun main() {
    println(1 + 1L)           // Long
    println(1L + 1)           // Long
    println(1 + 1.0)          // Double
    println(1.0f + 1.0)       // Double (Float widens)
    println(1.0 + 1.0f)       // Double
    println(1L + 1.0)         // Double
    println(1L + 1.0f)        // Float
    // Byte/Short arithmetic promotes to Int.
    val b1: Byte = 1
    val b2: Byte = 2
    val br = b1 + b2
    println(br)
    println(br is Int)
}
