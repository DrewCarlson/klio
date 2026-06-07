import kotlin.math.cbrt
import kotlin.math.round
import kotlin.math.sign
import kotlin.math.roundToInt
import kotlin.math.roundToLong

fun main() {
    println(cbrt(27.0))
    println(cbrt(-8.0))

    println(2.4.roundToInt())
    println(2.5.roundToInt())
    println((-2.5).roundToInt())
    println(2.6.roundToLong())

    println(round(2.5))
    println(round(3.5))
    println(round(-2.5))

    println(sign(0.0))
    println(sign(-0.0))
    println(sign(-5.0))
    println(sign(3.0))

    println(0x0F00.takeHighestOneBit())
    println(0x0F00.takeLowestOneBit())
    println(0.takeHighestOneBit())
    println(1.rotateLeft(4))
    println(0x12345678.rotateRight(8))
    println(1L.rotateLeft(4))

    println(5.5 % 2.0)
    println(-5.5 % 2.0)
    println(5.5.rem(2.0))
    println(5.5.mod(2.0))
    println((-5.5).mod(2.0))
    println(7.0 % 3)
}
