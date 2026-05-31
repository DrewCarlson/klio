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
    // the IEEE < > == operators keep their non-total semantics
    println(Double.NaN < 1.0)
    println(Double.NaN > 1.0)
    println(Double.NaN == Double.NaN)
    println(0.0 == -0.0)
    // Float total order
    println(listOf(2.0f, Float.NaN, 1.0f, -0.0f, 0.0f).sorted())
    println(Float.NaN.compareTo(1.0f))
}
