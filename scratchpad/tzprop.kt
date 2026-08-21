import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }

    // read only
    println("read only        = " + f.parse("UTC]").timeZoneId)

    // now WRITE the same property name in this frame, then read again
    val bag = DateTimeComponents()
    bag.timeZoneId = "Europe/Berlin"
    println("after write, read= " + f.parse("UTC]").timeZoneId)
    println("write value back = " + bag.timeZoneId)

    // several reads after the write
    for (z in listOf("EST", "GMT", "America/New_York")) {
        println("  $z -> " + f.parse("$z]").timeZoneId)
    }
}
