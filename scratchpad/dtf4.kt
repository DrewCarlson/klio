import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S3 {
    @Test
    fun a1() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            alternativeParsing({ char(',') }) { char('.') }
            secondFraction(fixedLength = 3)
        }
        check(LocalTime.parse("08:30:15,123", customFormat) == LocalTime(8, 30, 15, 123_000_000))
    }
    @Test
    fun a2() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            alternativeParsing({ char(',') }) { char('.') }
            secondFraction(fixedLength = 3)
        }
        check(LocalTime.parseOrNull("08:30:15,123", customFormat) == LocalTime(8, 30, 15, 123_000_000))
    }
    @Test
    fun a3() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            char(','); secondFraction(fixedLength = 3)
        }
        val time = LocalTime(8, 30, 15, 123_456_789)
        println("  a3 = " + time.format(customFormat))
        check(time.format(customFormat) == "08:30:15,123")
    }
}
