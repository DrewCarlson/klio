import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun newFormat() = DateTimeComponents.Format {
    dateTime(LocalDateTime.Formats.ISO)
    offset(UtcOffset.Formats.ISO)
    char('['); timeZoneId(); char(']')
}

fun countBad(f: kotlinx.datetime.format.DateTimeFormat<DateTimeComponents>): Int {
    var bad = 0
    for (z in TimeZone.availableZoneIds) {
        if (f.parse("2008-06-03T11:05:30.123456789+01:00[$z]").timeZoneId != z) bad++
    }
    return bad
}

fun main() {
    val a = newFormat()
    val b = newFormat()
    println("a before = " + countBad(a))
    a.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
    println("a after  = " + countBad(a))
    println("b (never formatted) = " + countBad(b))
    val c = newFormat()
    println("c (fresh, after a poisoned) = " + countBad(c))
}
