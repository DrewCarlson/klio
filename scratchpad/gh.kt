interface DateFields { var year: Int? }
class IncDate : DateFields { override var year: Int? = null }
interface TimeFields { var hour: Int? }
class IncTime : TimeFields { override var hour: Int? = null }

class Contents(
    val date: IncDate = IncDate(),
    val time: IncTime = IncTime(),
    var tz: String? = null,
) : DateFields by date, TimeFields by time

class Facade(internal val contents: Contents = Contents()) {
    var tz: String? by contents::tz
    var year: Int? by contents::year
}

fun main() {
    val a = Facade()
    a.tz = "Europe/Berlin"
    println("a.tz = " + a.tz)
    val b = Facade()
    b.contents.tz = "America/New_York"
    b.contents.year = 2008
    println("b.tz = " + b.tz + " b.year = " + b.year)
}
