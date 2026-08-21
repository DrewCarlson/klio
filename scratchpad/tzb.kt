import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents
import kotlinx.datetime.format.char
import kotlinx.datetime.format.format

fun greedy(tag: String) {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("  [$tag] UTC -> " + f.parse("UTC]").timeZoneId)
}

fun main() {
    greedy("start")

    val format = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('[')
        timeZoneId()
        char(']')
    }
    greedy("after-build")

    val berlin = "Europe/Berlin"
    val dateTime = LocalDateTime(2008, 6, 3, 11, 5, 30, 123_456_789)
    val offset = UtcOffset(hours = 1)

    val out = format.format { setDateTime(dateTime); setOffset(offset); timeZoneId = berlin }
    println("  formatted = $out")
    greedy("after-format")

    val bag = format.parse("2008-06-03T11:05:30.123456789+01:00[Europe/Berlin]")
    greedy("after-parse")

    println("  toLocalDateTime = " + bag.toLocalDateTime())
    greedy("after-toLocalDateTime")

    println("  toUtcOffset = " + bag.toUtcOffset())
    greedy("after-toUtcOffset")
}
