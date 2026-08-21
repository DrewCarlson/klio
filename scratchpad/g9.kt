import kotlinx.datetime.*
import kotlinx.datetime.format.*
fun main() {
    val g = DateTimeComponents.Format { timeZoneId(); chars("]") }
    g.format { timeZoneId = "Europe/Berlin" }
    val b = g.parse("America/New_York]")
    println("getter   = " + b.timeZoneId)
    val out = runCatching { g.format { timeZoneId = b.timeZoneId ?: "MISSING" } }.getOrElse { "ERR" }
    println("reformat = " + out)
    val b2 = g.parse("Asia/Tokyo]")
    println("second   = " + b2.timeZoneId)
}
