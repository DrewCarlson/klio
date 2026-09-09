// A method that calls a SIBLING method on the same receiver (`this.mul(...)`,
// written bare in Kotlin) inside a hot loop. The whole-function tier cannot
// take this shape — the receiver flows through a Move into the call's receiver
// slot — so the body must stay on the fused walk instead of yielding to a tier
// that never compiles it. Output must match with the JIT off (--opt safe) or on.
class Vec(var x: Int, var y: Int) {
    fun mul(a: Int, b: Int): Int = a * b
    fun scale(k: Int) { x = mul(x, k); y = mul(y, k) }
    fun sum(): Int = x + y
}

fun main() {
    val v = Vec(1, 2)
    var i = 0
    while (i < 200_000) { v.scale(1); i += 1 }
    println("sum=" + v.sum())
}
