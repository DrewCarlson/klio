import kotlinx.datetime.*
import kotlinx.datetime.format.*
fun main() {
    val f = DateTimeComponents.Format {
        dateTime(LocalDateTime.Formats.ISO); offset(UtcOffset.Formats.ISO)
        char('['); timeZoneId(); char(']')
    }
    println("combined -> " + f.parse("2008-06-03T11:05:30.123456789+01:00[America/New_York]").timeZoneId)
}
