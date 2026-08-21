import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val customFormat = LocalTime.Format {
        hour(); char(':'); minute(); char(':'); second()
        char(','); secondFraction(fixedLength = 3)
    }
    val time = LocalTime(8, 30, 15, 123_456_789)
    println("custom = " + time.format(customFormat))
    println("iso    = " + time.format(LocalTime.Formats.ISO))
}
