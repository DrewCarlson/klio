class Day(val n: Int) {
    operator fun rangeTo(end: Day): String = "Day(${n}..${end.n})"
    operator fun rangeUntil(end: Day): String = "Day(${n} until ${end.n})"
}

fun main() {
    println(Day(1)..Day(5))
    println(Day(1)..<Day(5))
}
