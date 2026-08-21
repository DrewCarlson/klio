import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

fun main() {
    val format = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('[')
        timeZoneId()
        char(']')
    }
    for (z in listOf("Europe/Berlin", "UTC", "America/New_York", "EST")) {
        val s = "2008-06-03T11:05:30.123456789+01:00[$z]"
        val got = runCatching { format.parse(s).timeZoneId }.getOrElse { "ERR " + it.message }
        println("$z -> $got")
    }
    val ids = runCatching { TimeZone.availableZoneIds }.getOrElse { emptySet() }
    println("availableZoneIds count = " + ids.size)
    println("first few = " + ids.take(5).toList())
}
