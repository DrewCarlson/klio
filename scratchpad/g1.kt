import kotlinx.datetime.*
import kotlinx.datetime.format.*
fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("greedy -> " + f.parse("America/New_York]").timeZoneId)
}
