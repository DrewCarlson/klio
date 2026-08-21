import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

fun main() {
    val greedy = DateTimeComponents.Format { timeZoneId(); chars("]") }
    var bad = 0
    for (z in TimeZone.availableZoneIds) {
        val got = runCatching { greedy.parse("$z]").timeZoneId }.getOrNull()
        if (got != z) {
            if (bad < 10) println("FAIL greedy $z -> $got")
            bad++
        }
    }
    println("greedy failures = $bad of " + TimeZone.availableZoneIds.size)
}
