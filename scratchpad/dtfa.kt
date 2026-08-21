import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*

class S9 {
    private val t = LocalTime(8, 30, 15, 123_456_789)
    @Test fun g1() { println("  g1 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 3) }.format(t)) }
    @Test fun g2() { println("  g2 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 3) }.format(t)) }
    @Test fun g3() { println("  g3 = " + LocalTime.Format { hour(); char('.'); secondFraction(fixedLength = 2) }.format(t)) }
    @Test fun g4() { println("  g4 = " + LocalTime.Format { hour(); char(','); secondFraction(fixedLength = 3) }.format(t)) }
    @Test fun g5() { println("  g5 = " + LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t)) }
}
