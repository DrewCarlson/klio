import kotlinx.datetime.*
import kotlinx.datetime.format.*
import kotlin.test.*
fun main() {
    val format = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('[')
        timeZoneId()
        char(']')
    }
    val berlin = "Europe/Berlin"
    val dateTime = LocalDateTime(2008, 6, 3, 11, 5, 30, 123_456_789)
    val offset = UtcOffset(hours = 1)

    var bad = 0
    for (zone in TimeZone.availableZoneIds) {
        if (format.parse("2008-06-03T11:05:30.123456789+01:00[$zone]").timeZoneId != zone) bad++
    }
    println("none bad=$bad")
}
