import kotlinx.datetime.TimeZone
import kotlinx.datetime.format.DateTimeComponents

class Holder {
    fun greedy(): String {
        val format = DateTimeComponents.Format { timeZoneId(); chars("]") }
        val sb = StringBuilder()
        for (z in listOf("UTC", "EST", "America/New_York")) {
            sb.append(z).append("->").append(format.parse("$z]").timeZoneId).append(" ")
        }
        return sb.toString()
    }
}

fun topLevel(): String {
    val format = DateTimeComponents.Format { timeZoneId(); chars("]") }
    val sb = StringBuilder()
    for (z in listOf("UTC", "EST", "America/New_York")) {
        sb.append(z).append("->").append(format.parse("$z]").timeZoneId).append(" ")
    }
    return sb.toString()
}

fun main() {
    println("top   = " + topLevel())
    println("class = " + Holder().greedy())
}
