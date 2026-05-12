// Integer-valued doubles render as `1.0`, not `1`. Infinity / NaN literal.
fun main() {
    println(1.0)
    println(0.0)
    println(42.0)
    println(0.5)
    println(1.0 / 0.0)        // Infinity
    println(-1.0 / 0.0)       // -Infinity
    println(0.0 / 0.0)        // NaN
}
