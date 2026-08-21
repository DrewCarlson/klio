import kotlin.math.abs
import kotlin.test.*

class T {
    private val range = (-3661..3661 step 1831)

    @Test
    fun parseAll() {
        fun Int.pad() = toString().padStart(2, '0')
        fun check(n: Int, s: String, canonical: Boolean = false) {
            println("  n=$n s=$s c=$canonical")
        }
        for (total in range) {
            val sign = if (total < 0) "-" else "+"
            val hours = abs(total / 60 / 60)
            val minutes = abs(total / 60 % 60)
            val seconds = abs(total % 60)
            check(total, "$sign${hours.pad()}:${minutes.pad()}:${seconds.pad()}", canonical = seconds != 0)
            if (seconds == 0) {
                check(total, "$sign${hours.pad()}:${minutes.pad()}", canonical = total != 0)
            }
        }
        check(0, "Z", canonical = true)
    }
}
