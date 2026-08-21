import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val f = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('['); timeZoneId(); char(']')
    }
    f.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
    var i = 0
    var firstBad = -1
    while (i < 120) {
        val got = f.parse("2008-06-03T11:05:30.123456789+01:00[America/New_York]").timeZoneId
        if (got != "America/New_York" && firstBad < 0) { firstBad = i; println("first bad at repeat $i -> $got") }
        i++
    }
    println("same-zone repeats=120 firstBad=$firstBad")
}
