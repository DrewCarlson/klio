// Hot Double arithmetic + comparison over a DoubleArray. The loop JIT compiles
// these to native SSE2 (addsd/mulsd/ucomisd …); output is identical with the
// JIT off or on, including IEEE/Kotlin NaN comparison semantics (any comparison
// with NaN is false except `!=`).
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
