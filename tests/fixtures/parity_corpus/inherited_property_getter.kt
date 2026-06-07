// A property with a custom getter declared on a (sealed) base class
// is read through a subclass instance — the getter resolves by
// walking the supertype chain.
sealed class Period {
    internal abstract val totalMonths: Long
    val years: Int get() = (totalMonths / 12).toInt()
    val months: Int get() = (totalMonths % 12).toInt()
}
class Months(override val totalMonths: Long) : Period()

fun main() {
    val p: Period = Months(14)
    println("${p.years}y ${p.months}m")
    val q: Period = Months(25)
    println("${q.years}y ${q.months}m")
}
