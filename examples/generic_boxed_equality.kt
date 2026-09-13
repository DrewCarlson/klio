// `==` compares by `equals` whenever the operand's static type is a type
// parameter, so `NaN` equals itself and `0.0` differs from `-0.0`. The static
// type has to survive the read: an element of an `Array<out T>`, a `List<T>`
// index and a member call returning `T` all carry `T` even though none of them
// spells it.

fun <T> allEqualIndexed(a: Array<out T>): Boolean {
    if (a.size < 2) return true
    val first = a[0]
    for (i in 1..a.lastIndex) {
        if (first != a[i]) return false
    }
    return true
}

fun <T> firstTwoEqual(l: List<T>): Boolean = l[0] == l[1]

fun <T> nextTwoEqual(i: Iterator<T>): Boolean = i.next() == i.next()

fun main() {
    val nan = arrayOf(Double.NaN, Double.NaN, Double.NaN)
    val zeros = arrayOf(0.0, -0.0)
    println(allEqualIndexed(nan))
    println(allEqualIndexed(zeros))
    println(allEqualIndexed(arrayOf(Float.NaN, Float.NaN)))
    println(firstTwoEqual(listOf(Double.NaN, Double.NaN)))
    println(firstTwoEqual(listOf(0.0, -0.0)))
    println(nextTwoEqual(listOf(Double.NaN, Double.NaN).iterator()))

    // A statically typed `Double` keeps the IEEE comparison.
    val x = Double.NaN
    println(x == Double.NaN)
    println(0.0 == -0.0)

    // The same split through `Any`.
    val boxed: Any = Double.NaN
    println(boxed == Double.NaN as Any)
    println((0.0 as Any) == (-0.0 as Any))
}
