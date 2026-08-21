import kotlinx.datetime.*
import kotlinx.datetime.format.*
fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("fmt -> " + f.format { timeZoneId = "Europe/Berlin" })
    println("parse -> " + f.parse("America/New_York]").timeZoneId)
}
