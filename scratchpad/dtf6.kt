import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S5 {
    @Test
    fun c1() {
        val f = LocalTime.Format {
            hour(); char(':'); minute()
            alternativeParsing({ char(',') }) { char('.') }
            second()
        }
        check(f.format(LocalTime(8, 30, 15)) == "08:30.15")
    }
    @Test
    fun c2() {
        val f = LocalTime.Format {
            hour(); char(':'); minute()
            alternativeParsing({ char(',') }) { char('.') }
            second()
        }
        check(f.format(LocalTime(8, 30, 15)) == "08:30.15")
    }
    @Test
    fun c3() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(','); second() }
        println("  c3 = " + f.format(LocalTime(8, 30, 15)))
        check(f.format(LocalTime(8, 30, 15)) == "08:30,15")
    }
}
