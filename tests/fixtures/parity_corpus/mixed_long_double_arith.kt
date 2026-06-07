// Mixed Long/Double arithmetic promotes Long to Double (Kotlin's
// numeric tower) for -, *, /, % (+ was already supported).
fun main() {
    val l = 5_000_000_000L
    println(l / 1_000_000_000.0)
    println(l - 0.5)
    println(7L * 2.5)
    println(10.0 / 4L)
    println(10.0 % 4L)
    println(7L % 2.5)
    println(2.0 - 9L)
}
