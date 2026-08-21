import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S4 {
    @Test
    fun b1() {
        val f = LocalTime.Format { hour(); char('.'); minute() }
        check(f.format(LocalTime(8, 30)) == "08.30")
    }
    @Test
    fun b2() {
        val f = LocalTime.Format { hour(); char('.'); minute() }
        check(f.format(LocalTime(8, 30)) == "08.30")
    }
    @Test
    fun b3() {
        val f = LocalTime.Format { hour(); char(','); minute() }
        println("  b3 = " + f.format(LocalTime(8, 30)))
        check(f.format(LocalTime(8, 30)) == "08,30")
    }
}
