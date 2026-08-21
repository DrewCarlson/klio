import kotlinx.datetime.*
fun main() {
    val g = listOf("Z", "+00:00", "-00:00", "+00:00:00", "-00:00:00").map { UtcOffset.parse(it) }
    println("vals    = " + g)
    println("secs    = " + g.map { it.totalSeconds })
    println("distinct= " + g.distinct().size)
    println("hashes  = " + g.map { it.hashCode() }.distinct())
    println("eq01    = " + (g[0] == g[1]))
    val h = listOf("+04:00", "+04:00:00").map { UtcOffset.parse(it) }
    println("h secs  = " + h.map { it.totalSeconds } + " distinct=" + h.distinct().size)
}
