import kotlinx.datetime.*

fun main() {
    val t = LocalDateTime(2007, 10, 28, 2, 30, 0, 0)
    val paris = TimeZone.of("Europe/Paris")
    println("overlap    = " + paris.localDateTimeToInstant(t))
    println("expected   = " + t.toInstant(UtcOffset(hours = 2)))
    // The gap (spring forward): 2007-03-25 02:30 does not exist in Paris.
    val gap = LocalDateTime(2007, 3, 25, 2, 30, 0, 0)
    println("gap        = " + paris.localDateTimeToInstant(gap))
    // Instant -> local across the autumn overlap.
    val berlin = TimeZone.of("Europe/Berlin")
    val i = Instant.parse("2019-10-27T00:59:00Z")
    println("berlin     = " + i.toLocalDateTime(berlin))
}
