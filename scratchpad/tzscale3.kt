import kotlinx.datetime.*
import kotlinx.datetime.format.*

class T {
    fun go(withFormat: Boolean): String {
        val f = DateTimeComponents.Format {
            dateTime(LocalDateTime.Formats.ISO)
            offset(UtcOffset.Formats.ISO)
            char('['); timeZoneId(); char(']')
        }
        if (withFormat) f.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
        var i = 0; var firstBad = -1; var bad = 0
        for (z in TimeZone.availableZoneIds) {
            val got = f.parse("2008-06-03T11:05:30.123456789+01:00[$z]").timeZoneId
            if (got != z) { if (firstBad < 0) firstBad = i; bad++ }
            i++
        }
        return "member withFormat=$withFormat total=$i bad=$bad firstBad=$firstBad"
    }
}

fun main() {
    println(T().go(false))
    println(T().go(true))
}
