// numeric fidelity: Float literals carry single-precision rounding
// distinct from Double.

fun main() {
    val a = 1.0f
    val b = 2.5f
    println(a + b)
    println(a is Float)
    println(a is Double)
    println(b is Float)
    // Single-precision rounding differs from Double for some values.
    println(0.1f + 0.2f)
    println(1.0f / 3.0f)
}
