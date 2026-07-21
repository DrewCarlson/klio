// klio actuals for the `expect fun minOf/maxOf` family declared in upstream
// `common/src/generated/_Comparisons.kt`. The numeric overloads reproduce the
// platform semantics (`Math.min`/`Math.max`: NaN propagates for Double/Float)
// and stay backed by the host intrinsic; their bodies carry the declared
// signatures so overload selection — static evidence at lowering, value-typed
// re-resolution at run time — can tell the numeric family apart from the
// generic one. The generic overloads compare through `compareTo`, so
// `minOf(0.0, NaN)` at a `Comparable`-typed call site follows the TOTAL order
// (NaN greatest, 0.0 wins) — that body really runs.

package kotlin.comparisons

public actual fun minOf(a: Byte, b: Byte): Byte {
    return if (a <= b) a else b
}

public actual fun minOf(a: Short, b: Short): Short {
    return if (a <= b) a else b
}

public actual fun minOf(a: Int, b: Int): Int {
    return if (a <= b) a else b
}

public actual fun minOf(a: Long, b: Long): Long {
    return if (a <= b) a else b
}

public actual fun minOf(a: Float, b: Float): Float {
    return kotlin.math.min(a, b)
}

public actual fun minOf(a: Double, b: Double): Double {
    return kotlin.math.min(a, b)
}

public actual fun minOf(a: Byte, b: Byte, c: Byte): Byte {
    return minOf(a, minOf(b, c))
}

public actual fun minOf(a: Short, b: Short, c: Short): Short {
    return minOf(a, minOf(b, c))
}

public actual fun minOf(a: Int, b: Int, c: Int): Int {
    return minOf(a, minOf(b, c))
}

public actual fun minOf(a: Long, b: Long, c: Long): Long {
    return minOf(a, minOf(b, c))
}

public actual fun minOf(a: Float, b: Float, c: Float): Float {
    return kotlin.math.min(a, kotlin.math.min(b, c))
}

public actual fun minOf(a: Double, b: Double, c: Double): Double {
    return kotlin.math.min(a, kotlin.math.min(b, c))
}

public actual fun minOf(a: Byte, vararg other: Byte): Byte {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun minOf(a: Short, vararg other: Short): Short {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun minOf(a: Int, vararg other: Int): Int {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun minOf(a: Long, vararg other: Long): Long {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun minOf(a: Float, vararg other: Float): Float {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun minOf(a: Double, vararg other: Double): Double {
    var min = a
    for (value in other) min = minOf(min, value)
    return min
}

public actual fun maxOf(a: Byte, b: Byte): Byte {
    return if (a >= b) a else b
}

public actual fun maxOf(a: Short, b: Short): Short {
    return if (a >= b) a else b
}

public actual fun maxOf(a: Int, b: Int): Int {
    return if (a >= b) a else b
}

public actual fun maxOf(a: Long, b: Long): Long {
    return if (a >= b) a else b
}

public actual fun maxOf(a: Float, b: Float): Float {
    return kotlin.math.max(a, b)
}

public actual fun maxOf(a: Double, b: Double): Double {
    return kotlin.math.max(a, b)
}

public actual fun maxOf(a: Byte, b: Byte, c: Byte): Byte {
    return maxOf(a, maxOf(b, c))
}

public actual fun maxOf(a: Short, b: Short, c: Short): Short {
    return maxOf(a, maxOf(b, c))
}

public actual fun maxOf(a: Int, b: Int, c: Int): Int {
    return maxOf(a, maxOf(b, c))
}

public actual fun maxOf(a: Long, b: Long, c: Long): Long {
    return maxOf(a, maxOf(b, c))
}

public actual fun maxOf(a: Float, b: Float, c: Float): Float {
    return kotlin.math.max(a, kotlin.math.max(b, c))
}

public actual fun maxOf(a: Double, b: Double, c: Double): Double {
    return kotlin.math.max(a, kotlin.math.max(b, c))
}

public actual fun maxOf(a: Byte, vararg other: Byte): Byte {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun maxOf(a: Short, vararg other: Short): Short {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun maxOf(a: Int, vararg other: Int): Int {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun maxOf(a: Long, vararg other: Long): Long {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun maxOf(a: Float, vararg other: Float): Float {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun maxOf(a: Double, vararg other: Double): Double {
    var max = a
    for (value in other) max = maxOf(max, value)
    return max
}

public actual fun <T : Comparable<T>> minOf(a: T, b: T): T {
    return if (a <= b) a else b
}

public actual fun <T : Comparable<T>> minOf(a: T, b: T, c: T): T {
    val ab = if (a <= b) a else b
    return if (ab <= c) ab else c
}

public actual fun <T : Comparable<T>> maxOf(a: T, b: T): T {
    return if (a >= b) a else b
}

public actual fun <T : Comparable<T>> maxOf(a: T, b: T, c: T): T {
    val ab = if (a >= b) a else b
    return if (ab >= c) ab else c
}

public actual fun <T : Comparable<T>> minOf(a: T, vararg other: T): T {
    var min = a
    for (value in other) if (min > value) min = value
    return min
}

public actual fun <T : Comparable<T>> maxOf(a: T, vararg other: T): T {
    var max = a
    for (value in other) if (max < value) max = value
    return max
}
