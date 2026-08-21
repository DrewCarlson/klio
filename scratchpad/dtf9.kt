import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S8 {
    @Test
    fun f1() {
        val f = LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 3) }
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08.123")
    }
    @Test
    fun f2() {
        val f = LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 3) }
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08.123")
    }
    @Test
    fun f3() {
        val f = LocalTime.Format { hour(); char(','); secondFraction(fixedLength = 3) }
        println("  f3 = " + f.format(LocalTime(8, 30, 15, 123_456_789)))
        check(f.format(LocalTime(8, 30, 15, 123_456_789)) == "08,123")
    }
}
