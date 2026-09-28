// Operators with a literal on one side: masks, shifts, compares in
// conditions and as values, a literal on the left, floating-point literals
// against signed zero and NaN, unsigned equality, and the operations a
// literal cannot finish alone (a zero divisor, the overflowing division).

fun ints(x: Int) {
    val masked = x and 0xff
    val shifted = x shl 3
    val high = x ushr 28
    val signed = x shr 4
    val scaled = x * 31 + 7 - 2
    val flipped = x xor -1
    val joined = 0x100 or x
    println("int $x: $masked $shifted $high $signed $scaled $flipped $joined ${x / 3} ${x % 5} ${x / -1} ${x % -1}")
    println("  ${x == 0} ${x != 7} ${x < 10} ${10 > x} ${x >= -3} ${-3 <= x} ${7 == x} ${3 - x}")
    if (x != 0) print("  nonzero") else print("  zero")
    if (100 < x) print(" big") else print(" small")
    if ((x and 1) == 0) println(" even") else println(" odd")
}

fun longs(x: Long) {
    println("long $x: ${x and 0xFFFFL} ${x shl 33} ${x ushr 60} ${x shr 1} ${x * 1_000_000_007L} ${x + Long.MIN_VALUE} ${x / 7L} ${x % 7L}")
    println("  ${x == 0L} ${x > 1L shl 40} ${-1L < x} ${x shl 3} ${x ushr 3}")
    if (x == Long.MAX_VALUE) println("  max") else println("  not max")
}

fun floats(f: Float, d: Double) {
    println("float $f: ${f * 2f} ${f + 0.5f} ${0.5f + f} ${f / 4f} ${f - 1f} ${f % 3f} ${f == 0f} ${f < 1f} ${1f > f}")
    println("double $d: ${d * 2.0} ${d + 0.25} ${d / 0.0} ${d == 0.0} ${d != -0.0} ${d >= 1.5} ${2.0 <= d}")
    if (f > 0f) println("  positive") else println("  not positive")
}

fun unsigned(u: ULong, v: UInt) {
    println("unsigned $u $v: ${u == 0uL} ${u != 18446744073709551615uL} ${v == 4294967295u} ${v != 1u}")
    if (u == 18446744073709551615uL) println("  max") else println("  not max")
}

fun mixed(b: Byte, s: Short, c: Char, any: Any) {
    println("mixed: ${b + 1} ${s * 2} ${b.toInt() and 0x0f} ${c + 1} ${c.code - 64} ${any == 3} ${any == 3L}")
}

fun divideByZero(x: Int, y: Long) {
    try {
        println(x / 0)
    } catch (e: ArithmeticException) {
        println("int: ${e.message}")
    }
    try {
        println(y % 0L)
    } catch (e: ArithmeticException) {
        println("long: ${e.message}")
    }
}

fun main() {
    for (x in intArrayOf(0, 1, 7, -3, 255, 256, 1000, Int.MAX_VALUE, Int.MIN_VALUE)) ints(x)
    for (x in longArrayOf(0L, 1L, -1L, 1L shl 41, Long.MAX_VALUE, Long.MIN_VALUE)) longs(x)
    for (f in floatArrayOf(0f, -0f, 1f, -2.5f, Float.NaN, Float.POSITIVE_INFINITY)) floats(f, f.toDouble())
    unsigned(0uL, 1u)
    unsigned(18446744073709551615uL, 4294967295u)
    mixed(-128, 30000, 'A', 3)
    mixed(127, -1, 'z', 3L)
    divideByZero(9, 9L)
    var sum = 0
    var i = 0
    while (i < 1000) {
        if (i % 7 != 0) sum += i and 0x3f
        i += 3
    }
    println("sum $sum")
}
