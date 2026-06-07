import kotlin.math.*

fun main() {
    println(sinh(0.0))
    println(cosh(0.0))
    println(tanh(0.0))
    println(asinh(0.0))
    println(acosh(1.0))
    println(atanh(0.0))
    println(expm1(0.0))
    println(ln1p(0.0))
    println(2.0f.pow(10))
    println(3.0f.pow(2.0f))
    // math intrinsics now accept any numeric operand (Float/Long too)
    println(sqrt(16.0f.toDouble()))
    println(tanh(1L.toDouble()))
}
