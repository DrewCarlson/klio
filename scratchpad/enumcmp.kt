enum class Day { MONDAY, SATURDAY, SUNDAY }

fun main() {
    val a = Day.SUNDAY
    val b = Day.SATURDAY
    println("compareTo  = " + a.compareTo(b))
    println("greater    = " + (a > b))
    println("less       = " + (a < b))
    println("sorted     = " + listOf(Day.SUNDAY, Day.MONDAY, Day.SATURDAY).sorted())
    println("max        = " + maxOf(a, b))
    println("coerce     = " + a.coerceAtMost(b))
    println("range      = " + (Day.MONDAY..Day.SUNDAY).contains(Day.SATURDAY))
}
