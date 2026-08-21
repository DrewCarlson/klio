import kotlinx.datetime.*
import kotlinx.datetime.format.*

fun churn(n: Int): Int { var a = 0; for (i in 0 until n) { val s = "y" + i; a += s.length }; return a }

fun main() {
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    println("fmt -> " + f.format { timeZoneId = "Europe/Berlin" })
    val b = f.parse("America/New_York]")
    churn(40)
    println("parse -> " + b.timeZoneId)
    churn(40)
    println("again -> " + b.timeZoneId)
}
