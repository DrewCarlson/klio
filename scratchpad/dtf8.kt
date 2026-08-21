import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S7 {
    @Test
    fun e1() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char('.'); second() }
        check(f.format(LocalTime(8, 30, 15)) == "08:30:15.15")
    }
    @Test
    fun e2() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char('.'); second() }
        check(f.format(LocalTime(8, 30, 15)) == "08:30:15.15")
    }
    @Test
    fun e3() {
        val f = LocalTime.Format { hour(); char(':'); minute(); char(':'); second(); char(','); second() }
        println("  e3 = " + f.format(LocalTime(8, 30, 15)))
        check(f.format(LocalTime(8, 30, 15)) == "08:30:15,15")
    }
}
