import kotlin.time.Instant

fun main() {
    val a = Instant.fromEpochSeconds(1000)
    val b = Instant.fromEpochSeconds(2000)
    println("lt = " + (a < b))
    println("cmp = " + a.compareTo(b))
    println("is Comparable = " + (a is Comparable<*>))
    println("sorted = " + listOf(b, a).sorted().first())
}
