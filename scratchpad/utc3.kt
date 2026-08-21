import kotlinx.datetime.*

fun main() {
    val a = UtcOffset(hours = 1)
    val b = UtcOffset(hours = 1)
    println("cache 1h same = " + (a === b) + " eq=" + (a == b))
    val z1 = UtcOffset(hours = 0)
    val z2 = UtcOffset(hours = 0)
    println("0h same = " + (z1 === z2))
    println("0h == ZERO = " + (z1 == UtcOffset.ZERO) + " total=" + z1.totalSeconds + "/" + UtcOffset.ZERO.totalSeconds)
    val s = UtcOffset(seconds = 0)
    println("seconds0 vs hours0 same = " + (s === z1))
}
