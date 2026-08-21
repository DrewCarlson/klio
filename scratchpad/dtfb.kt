import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val t = LocalTime(8, 30, 15, 123_456_789)
    for (i in 1..5) {
        val f = LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = i) }
        println("loop i=$i -> " + f.format(t))
    }
    println("s1 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 3) }.format(t))
    println("s2 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 2) }.format(t))
    println("s3 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 1) }.format(t))
}
