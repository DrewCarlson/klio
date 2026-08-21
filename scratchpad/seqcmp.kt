import kotlin.time.Instant

class Ver(val n: Int) : Comparable<Ver> {
    override fun compareTo(other: Ver): Int = n.compareTo(other.n)
    override fun toString(): String = "v$n"
}

fun main() {
    val vs = listOf(Ver(3), Ver(1), Ver(2))
    println("list sorted   = " + vs.sorted())
    println("list sortedBy = " + vs.sortedBy { it })
    println("seq sorted    = " + vs.asSequence().sorted().toList())
    println("seq sortedBy  = " + vs.asSequence().sortedBy { it }.toList())
    println("max/min       = " + vs.max() + "/" + vs.min())
    println("coerce        = " + Ver(5).coerceAtMost(Ver(2)))
    val ts = listOf(Instant.fromEpochSeconds(30), Instant.fromEpochSeconds(10))
    println("instants      = " + ts.asSequence().sortedBy { it }.toList().first())
}
