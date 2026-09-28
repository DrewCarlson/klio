// The numeric functions of one value the interpreter computes as
// instructions: the floating-point bit views, trailing-zero counts,
// inversion, the unsigned types' conversions to floating point, and sin,
// cos and sqrt, at their edges.
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

fun main() {
    for (f in floatArrayOf(1f, -0f, Float.NaN, Float.POSITIVE_INFINITY, Float.MIN_VALUE)) {
        println("F $f ${f.toRawBits()} ${f.toBits()} ${Float.fromBits(f.toRawBits())}")
    }
    for (d in doubleArrayOf(1.0, -0.0, Double.NaN, Double.NEGATIVE_INFINITY, Double.MIN_VALUE)) {
        println("D $d ${d.toRawBits()} ${d.toBits()} ${Double.fromBits(d.toRawBits())}")
    }
    val oddNan = Float.fromBits(0x7fc00001)
    println("nan ${oddNan.toRawBits()} ${oddNan.toBits()} ${Double.fromBits(0x7ff0000000000001L).toBits()}")
    println("fromBits ${Float.fromBits(Int.MIN_VALUE)} ${Float.fromBits(0x3f800000)} ${Double.fromBits(4611686018427387904L)}")
    for (i in intArrayOf(0, 1, 8, -1, Int.MIN_VALUE, 0x10000)) {
        println("I $i ${i.inv()} ${i.countTrailingZeroBits()} ${i.hashCode()} ${i.toUInt().toFloat()} ${i.toUInt().toDouble()}")
    }
    for (l in longArrayOf(0L, 1L, -1L, Long.MIN_VALUE, 1L shl 40)) {
        println("L $l ${l.inv()} ${l.countTrailingZeroBits()} ${l.toULong().toFloat()} ${l.toULong().toDouble()}")
    }
    println("U ${0u.countTrailingZeroBits()} ${ULong.MAX_VALUE.countTrailingZeroBits()} ${(0).toUByte().countTrailingZeroBits()} ${(4).toUShort().countTrailingZeroBits()} ${(0).toUShort().countTrailingZeroBits()}")
    println("S ${(0).toShort().countTrailingZeroBits()} ${(-128).toByte().countTrailingZeroBits()} ${(0).toByte().countTrailingZeroBits()}")
    for (x in doubleArrayOf(0.0, -0.0, 1.0, 2.0, 4.0, Double.NaN, Double.POSITIVE_INFINITY, -1.0)) {
        println("M $x ${sin(x)} ${cos(x)} ${sqrt(x)}")
    }
    for (x in floatArrayOf(0f, -0f, 1f, 9f, Float.NaN, -4f)) {
        println("MF $x ${sin(x)} ${cos(x)} ${sqrt(x)}")
    }
}
