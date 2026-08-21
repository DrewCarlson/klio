import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S6 {
    @Test
    fun d1() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char('.'); secondFraction(fixedLength = 3) }
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08:30:15.123")
    }
    @Test
    fun d2() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char('.'); secondFraction(fixedLength = 3) }
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08:30:15.123")
    }
    @Test
    fun d3() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char(','); secondFraction(fixedLength = 3) }
        println("  d3 = " + f.format(LocalTime(8, 30, 15, 123_456_789)))
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08:30:15,123")
    }
}
