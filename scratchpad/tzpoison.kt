import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

fun greedyCheck(tag: String) {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("$tag UTC -> " + f.parse("UTC]").timeZoneId)
}

fun main() {
    greedyCheck("before")

    // What testZonedDateTime does: a combined format over every zone id.
    val format = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO)
        offset(UtcOffset.Formats.ISO)
        char('[')
        timeZoneId()
        char(']')
    }
    var bad = 0
    for (z in TimeZone.availableZoneIds) {
        val got = runCatching { format.parse("2008-06-03T11:05:30.123456789+01:00[$z]").timeZoneId }.getOrNull()
        if (got != z) { if (bad < 3) println("  combined FAIL $z -> $got"); bad++ }
    }
    println("combined failures = $bad")

    greedyCheck("after")
}
