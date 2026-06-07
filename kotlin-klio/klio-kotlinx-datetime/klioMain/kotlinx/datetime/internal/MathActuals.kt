package kotlinx.datetime.internal

// klio platform actuals for the kotlinx.datetime.internal math
// expects. JVM uses Math.addExact / Math.multiplyExact (throw
// ArithmeticException on overflow); these are equivalent pure-Kotlin
// overflow checks. Int variants check via a Long round-trip.

internal actual fun safeAdd(a: Long, b: Long): Long {
    val r = a + b
    if ((a xor r) and (b xor r) < 0L) {
        throw ArithmeticException("Long overflow: $a + $b")
    }
    return r
}

internal actual fun safeAdd(a: Int, b: Int): Int {
    val r = a.toLong() + b.toLong()
    val t = r.toInt()
    if (t.toLong() != r) throw ArithmeticException("Int overflow: $a + $b")
    return t
}

internal actual fun safeMultiply(a: Long, b: Long): Long {
    if (a == 0L || b == 0L) return 0L
    val r = a * b
    if (r / b != a || (a == Long.MIN_VALUE && b == -1L) || (b == Long.MIN_VALUE && a == -1L)) {
        throw ArithmeticException("Long overflow: $a * $b")
    }
    return r
}

internal actual fun safeMultiply(a: Int, b: Int): Int {
    val r = a.toLong() * b.toLong()
    val t = r.toInt()
    if (t.toLong() != r) throw ArithmeticException("Int overflow: $a * $b")
    return t
}
