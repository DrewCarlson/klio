import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S2 {
    @Test
    fun aParse() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            alternativeParsing({ char(',') }) { char('.') }
            secondFraction(fixedLength = 3)
        }
        println("  aParse fmt = " + LocalTime(8, 30, 15, 123_000_000).format(customFormat))
    }

    @Test
    fun bCustom() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            char(','); secondFraction(fixedLength = 3)
        }
        val time = LocalTime(8, 30, 15, 123_456_789)
        println("  bCustom fmt = " + time.format(customFormat))
        check(time.format(customFormat) == "08:30:15,123")
    }
}
