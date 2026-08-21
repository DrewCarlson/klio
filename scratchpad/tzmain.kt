import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun newF() = DateTimeComponents.Format {
    dateTime(LocalDateTime.Formats.ISO); offset(UtcOffset.Formats.ISO)
    char('['); timeZoneId(); char(']')
}
fun fmt(f: kotlinx.datetime.format.DateTimeFormat<DateTimeComponents>) {
    f.format { setDateTime(LocalDateTime(2008, 6, 3, 11, 5, 30, 123456789)); setOffset(UtcOffset(hours = 1)); timeZoneId = "Europe/Berlin" }
}

fun inFunction(): Int {
    val f = newF(); fmt(f)
    var i = 0; var bad = 0
    while (i < 200) {
        if (f.parse("2008-06-03T11:05:30.123456789+01:00[America/New_York]").timeZoneId != "America/New_York") bad++
        i++
    }
    return bad
}

fun main() {
    println("in function = " + inFunction())
    val f = newF(); fmt(f)
    var i = 0; var bad = 0
    while (i < 200) {
        if (f.parse("2008-06-03T11:05:30.123456789+01:00[America/New_York]").timeZoneId != "America/New_York") bad++
        i++
    }
    println("in main     = " + bad)
}
