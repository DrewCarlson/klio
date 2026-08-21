import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("before = " + f.parse("America/New_York]").timeZoneId)
    val s = f.format { timeZoneId = "Europe/Berlin" }
    println("formatted = " + s)
    for (z in listOf("America/New_York", "EST", "UTC", "America/Argentina/Cordoba")) {
        println("  after $z -> " + f.parse("$z]").timeZoneId)
    }
}
