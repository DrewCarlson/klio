package kotlinx.datetime.test.samples2

import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.random.*
import kotlin.test.*

class S {
    @Test
    fun customFormat() {
        val customFormat = LocalTime.Format {
            hour(); char(':'); minute(); char(':'); second()
            char(','); secondFraction(fixedLength = 3)
        }
        val time = LocalTime(8, 30, 15, 123_456_789)
        println("  a=" + time.format(customFormat))
        println("  b=" + time.format(LocalTime.Formats.ISO))
        check(time.format(customFormat) == "08:30:15,123")
        check(time.format(LocalTime.Formats.ISO) == "08:30:15.123456789")
    }
}
