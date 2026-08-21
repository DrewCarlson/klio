import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val t = LocalTime(8, 30, 15, 123_456_789)
    println("1 = " + LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t))
    println("2 = " + LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t))
    println("3 = " + LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t))
    println("4 = " + LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t))
}
