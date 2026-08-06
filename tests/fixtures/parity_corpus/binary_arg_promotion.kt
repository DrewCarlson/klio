// Arithmetic promotes to the wider operand and comparison is Boolean, in
// the channel the inline splice consults — so a lambda parameter bound from
// `f(a + b)` or `f(a > b)` keeps a receiver.
fun main() {
    val ints = listOf(1, 2, 3)
    println(ints.map { n -> (n + 1).toLong() }.joinToString(","))
    println(ints.map { n -> (n * 2L).toString() }.joinToString(","))
    println(ints.map { n -> (n > 1).toString() }.joinToString(","))

    val a = 3
    val b = 2L
    val widened = a + b
    println(widened.toString())
    val ratio = a.toDouble() / 2
    println(ratio.toInt().toString())
    val flag = a >= 3 && b < 5L
    println(flag.toString().length.toString())
}
