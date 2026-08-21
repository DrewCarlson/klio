import kotlin.math.abs

fun outer() {
    fun Int.pad() = toString().padStart(2, '0')
    // A local function named `check` SHADOWS kotlin.check.
    fun check(n: Int, s: String, canonical: Boolean = false) {
        println("  check n=$n s=$s canonical=$canonical")
    }

    for (total in listOf(-3661, 0, 3661)) {
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

fun main() { outer() }
