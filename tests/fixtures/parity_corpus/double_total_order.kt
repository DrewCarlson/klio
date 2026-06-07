fun <T : Comparable<T>> myMax(a: T, b: T): T = if (a >= b) a else b
fun <T : Comparable<T>> myMin(a: T, b: T): T = if (a <= b) a else b

fun main() {
    // sorting uses Kotlin's total order: NaN is greatest, -0.0 < 0.0
    println(listOf(3.0, Double.NaN, 1.0, -0.0, 0.0, 2.0).sorted())
    println(listOf(Double.NaN, 1.0, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY).sorted())
    // compareTo is the same total order
    println(0.0.compareTo(-0.0))
    println((-0.0).compareTo(0.0))
    println(Double.NaN.compareTo(1.0))
    println(Double.NaN.compareTo(Double.POSITIVE_INFINITY))
    println(1.0.compareTo(Double.NaN))
    println(Double.NaN.compareTo(Double.NaN))
    // the IEEE < > == operators on concrete Double keep their non-total semantics
    println(Double.NaN < 1.0)
    println(Double.NaN > 1.0)
    println(Double.NaN == Double.NaN)
    println(0.0 == -0.0)
    // a comparison operator on a generic Comparable type-parameter desugars to
    // compareTo (the total order), so a user maxOf/minOf propagates NaN.
    println(myMax(Double.NaN, 1.0))
    println(myMin(Double.NaN, 1.0))
    println(myMax(3, 9))
    println(myMin(3, 9))
    println(myMax("a", "b"))
    // the stdlib maxOf/minOf use Math.min/max for floats — NaN
    // propagates regardless of argument order or numeric type.
    println(maxOf(Double.NaN, 1.0))
    println(minOf(Double.NaN, 1.0))
    println(maxOf(1.0, Double.NaN))
    println(minOf(1.0, Double.NaN))
    println(maxOf(2.0f, Float.NaN))
    println(maxOf(3.0, 7.0))
    println(minOf(3.0, 7.0))
    println(maxOf(1, 5))
    println(minOf(7, 2))
    println(maxOf(1L, 9L))
    println(maxOf("a", "b"))
    println(minOf("a", "b"))
    // Float total order
    println(listOf(2.0f, Float.NaN, 1.0f, -0.0f, 0.0f).sorted())
    println(Float.NaN.compareTo(1.0f))
}
