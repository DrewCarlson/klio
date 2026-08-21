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

fun doFormat(f: kotlinx.datetime.format.DateTimeFormat<DateTimeComponents>) {
    f.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
}

fun main() {
    val parseFirst = newFormat()
    println("parse-first: before=" + countBad(parseFirst))
    doFormat(parseFirst)
    println("parse-first: after =" + countBad(parseFirst))

    val formatFirst = newFormat()
    doFormat(formatFirst)
    println("format-first: after=" + countBad(formatFirst))
}
