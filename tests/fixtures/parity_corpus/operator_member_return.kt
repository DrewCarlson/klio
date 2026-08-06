// An arithmetic operator on a CLASS is a member call, and its declared
// return types the local it initializes.
class Money(val cents: Long) {
    operator fun div(n: Int): Money = Money(cents / n)
    operator fun plus(other: Money): Money = Money(cents + other.cents)
    operator fun times(n: Int): Money = Money(cents * n)
    fun render(): String = "$cents"
}

fun main() {
    val total = Money(1000)
    val half = total / 2
    println(half.render())
    val doubled = half * 2
    println(doubled.render())
    val sum = half + doubled
    println(sum.render())

    val d = with(kotlin.time.Duration) { 10.toDuration(kotlin.time.DurationUnit.SECONDS) }
    val piece = d / 2
    println(piece.inWholeSeconds.toString())
}
