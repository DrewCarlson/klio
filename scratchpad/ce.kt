enum class Day { MON, SAT, SUN }
fun main() { println(Day.SUN.coerceAtMost(Day.SAT)) }
