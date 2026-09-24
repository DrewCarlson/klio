// Double arithmetic and comparison over a DoubleArray, including a NaN
// element: Kotlin's NaN comparison semantics say any comparison with NaN is
// false except `!=`, so `v == v` is false only for that element.
fun main() {
    val n = 1000
    val a = DoubleArray(n)
    var x = -1.0
    var i = 0
    while (i < n) {
        a[i] = x
        x = x + 0.5
        i = i + 1
    }
    a[0] = 0.0 / 0.0 // NaN

    var sum = 0.0
    var inRange = 0
    var ordered = 0
    i = 0
    while (i < n) {
        val v = a[i]
        sum = sum + v * 2.0 - 0.5
        if (v > 0.0 && v < 100.0) inRange = inRange + 1
        if (v == v) ordered = ordered + 1 // false only for NaN
        i = i + 1
    }
    println("sum=$sum inRange=$inRange ordered=$ordered")
}
