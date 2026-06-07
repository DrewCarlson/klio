// Qualified / nested type references in type position: nested-class
// parameter and return types, nullable nested type, and nested-type
// construction + member access. Exercises the parser's qualified
// type-path support.
class DateTimeUnit {
    class TimeBased(val nanos: Long) {
        fun seconds(): Long = nanos / 1_000_000_000
    }
    class DateBased(val days: Int)
}

fun span(unit: DateTimeUnit.TimeBased): Long = unit.seconds()

fun makeDays(n: Int): DateTimeUnit.DateBased = DateTimeUnit.DateBased(n)

fun describe(u: DateTimeUnit.DateBased?): String =
    if (u == null) "none" else "days=${u.days}"

fun main() {
    val t = DateTimeUnit.TimeBased(5_000_000_000L)
    println(span(t))
    val d: DateTimeUnit.DateBased = makeDays(7)
    println(d.days)
    println(describe(d))
    println(describe(null))
}
