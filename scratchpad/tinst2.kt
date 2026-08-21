import kotlinx.datetime.*
import kotlin.time.Instant

fun main() {
    val a = Instant.fromEpochSeconds(1000L)
    val b = LocalDateTime(2038, 1, 1, 0, 0).toInstant(UtcOffset.ZERO)
    println("a=$a b=$b")
    println("lt = " + (a < b))
    val xs = listOf(1000L, 2000L)
    println("all = " + xs.all { Instant.fromEpochSeconds(it) < b })
}
