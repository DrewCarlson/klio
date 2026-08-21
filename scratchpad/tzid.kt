import kotlinx.datetime.format.DateTimeComponents

fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    for (z in listOf("UTC", "America/New_York", "EST", "z")) {
        val got = runCatching { f.parse("$z]").timeZoneId }.getOrElse { "ERR " + it.message }
        println("$z -> $got")
    }
    // write side
    val w = DateTimeComponents.Format { timeZoneId() }
    println("format = " + runCatching { w.format { timeZoneId = "Europe/Berlin" } }.getOrElse { "ERR " + it.message })
}
