// An integer literal has no `Double` type in Kotlin, so it cannot pick a
// floating overload over an integer one, and an unannotated `const val` over a
// builtin scalar's companion constant states its type as plainly as a literal
// does. Both are overload evidence, and without either the pick falls to
// declaration order.
//
// Run with: klio run examples/integer_literal_never_floats.kt

const val NANOS_IN_MILLIS = 1_000_000
const val MAX_NANOS = Long.MAX_VALUE / 2 / NANOS_IN_MILLIS * NANOS_IN_MILLIS - 1

fun scale(value: Double, by: Int): Double = value + by
fun scale(value: Long, by: Int): Long = value + by

fun Long.kind(): String = "Long"
fun Double.kind(): String = "Double"

fun main() {
    // The literal `1` is an Int, so the Long overload takes it.
    println("literal      = " + scale(1, 0).kind())
    // `MAX_NANOS` is a Long by inference through the arithmetic.
    println("const        = " + scale(MAX_NANOS, 0).kind())
    // A float literal still reaches the floating overload.
    println("float        = " + scale(1.0, 0).kind())
    // The chosen overload decides the expression's type, and so the extension.
    val truncated = MAX_NANOS - MAX_NANOS % scale(1, 0)
    println("derived      = " + truncated.kind())
    println("value        = " + truncated)
}
