import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

fun main() {
    val ids = TimeZone.availableZoneIds
    println("count = " + ids.size)
    println("has Lower_Princes = " + ids.contains("America/Lower_Princes"))
    val long = ids.filter { it.length > 18 }.take(6)
    println("longest few = " + long)
    val format = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO); offset(UtcOffset.Formats.ISO)
        char('['); timeZoneId(); char(']')
    }
    for (z in listOf("America/Lower_Princes", "America/Edmonton", "America/Argentina/Buenos_Aires")) {
        val got = runCatching { format.parse("2008-06-03T11:05:30.123456789+01:00[$z]").timeZoneId }.getOrElse { "ERR" }
        println("$z -> $got")
    }
    val greedy = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("greedy Lower_Princes -> " + runCatching { greedy.parse("America/Lower_Princes]").timeZoneId }.getOrElse { "ERR" })
}
