// A bare integer literal takes the type of its expected context, so a
// `0` / `1` flowing into a `Long` slot is a `Long`, not an `Int`. This
// matters at runtime because `Long`-vs-`Int` equality is type-strict:
// `1L == 1` adapts the literal at compile time, but a value carrying a
// stray `Int` tag in a `Long` slot compares unequal. Exercise every
// slot kind plus the overflow-check idiom that motivated the fix.

class Unit1(val nanos: Long)

fun timesScalar(nanos: Long, scalar: Long): Long {
    val r = nanos * scalar
    // The kotlinx-datetime `safeMultiply` overflow guard: with a stray
    // `Int` `nanos`, `r / scalar != nanos` is spuriously true.
    if (r / scalar != nanos) throw ArithmeticException("overflow $nanos * $scalar")
    return r
}

fun acceptsLong(x: Long): Boolean = x == 1L

fun returnsLong(): Long = 1

fun main() {
    // function argument
    println(acceptsLong(1))
    // constructor argument (positional + named) read back as a field
    println(Unit1(1).nanos == 1L)
    println(Unit1(nanos = 1).nanos == 1L)
    // return slot
    println(returnsLong() == 1L)
    // default argument already worked; keep it covered
    // the overflow idiom: 1 * 1000 must not be flagged as overflow
    println(timesScalar(Unit1(1).nanos, 1000))
    // local with annotation (already worked) for completeness
    val n: Long = 1
    println(n == 1L)
}
