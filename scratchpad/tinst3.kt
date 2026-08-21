import kotlin.time.Instant

class Rule<T>(val at: T, val tag: String)

fun main() {
    val xs = listOf(Rule(Instant.fromEpochSeconds(2000), "b"), Rule(Instant.fromEpochSeconds(1000), "a"))
    println("sortedBy = " + xs.sortedBy { it.at }.map { it.tag })
    println("compareValues = " + compareValues(Instant.fromEpochSeconds(1), Instant.fromEpochSeconds(2)))
    println("maxOf = " + maxOf(Instant.fromEpochSeconds(1), Instant.fromEpochSeconds(2)))
}
