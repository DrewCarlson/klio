enum class Day { MON, SAT, SUN }

class Ver(val n: Int) : Comparable<Ver> {
    override fun compareTo(other: Ver): Int = n - other.n
    override fun toString(): String = "v$n"
}

fun main() {
    println("enum coerceAtMost  = " + runCatching { Day.SUN.coerceAtMost(Day.SAT) }.getOrElse { "ERR " + it.message })
    println("enum coerceAtLeast = " + runCatching { Day.MON.coerceAtLeast(Day.SAT) }.getOrElse { "ERR " + it.message })
    println("enum coerceIn      = " + runCatching { Day.SUN.coerceIn(Day.MON, Day.SAT) }.getOrElse { "ERR " + it.message })
    println("user coerceAtMost  = " + runCatching { Ver(5).coerceAtMost(Ver(3)) }.getOrElse { "ERR " + it.message })
    println("int  coerceAtMost  = " + 5.coerceAtMost(3))
    println("str  coerceAtMost  = " + "b".coerceAtMost("a"))
}
