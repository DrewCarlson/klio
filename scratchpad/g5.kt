import kotlinx.datetime.*
import kotlinx.datetime.format.*
fun main() {
    val f = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO); offset(UtcOffset.Formats.ISO)
        char('['); timeZoneId(); char(']')
    }
    println("fmt -> " + f.format { setDateTime(LocalDateTime(2008,6,3,11,5,30,123456789)); setOffset(UtcOffset(hours=1)); timeZoneId = "Europe/Berlin" })
    println("parse -> " + f.parse("2008-06-03T11:05:30.123456789+01:00[America/New_York]").timeZoneId)
}
