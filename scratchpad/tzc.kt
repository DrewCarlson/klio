import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

fun main() {
    // No `import kotlinx.datetime.format.char` — exactly as the test writes it.
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
        if (got != z) { if (bad < 5) println("FAIL $z -> $got"); bad++ }
    }
    println("combined failures = $bad of " + TimeZone.availableZoneIds.size)
}
