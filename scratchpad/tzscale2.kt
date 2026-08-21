import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun run(withFormat: Boolean, rounds: Int): String {
    val f = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('['); timeZoneId(); char(']')
    }
    if (withFormat) f.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
    var i = 0; var firstBad = -1; var bad = 0
    var r = 0
    while (r < rounds) {
        for (z in TimeZone.availableZoneIds) {
            val got = f.parse("2008-06-03T11:05:30.123456789+01:00[$z]").timeZoneId
            if (got != z) { if (firstBad < 0) firstBad = i; bad++ }
            i++
        }
        r++
    }
    return "withFormat=$withFormat rounds=$rounds total=$i bad=$bad firstBad=$firstBad"
}

fun main() {
    println(run(false, 1))
    println(run(false, 3))
    println(run(true, 1))
}
