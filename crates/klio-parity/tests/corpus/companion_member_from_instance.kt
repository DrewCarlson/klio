// A companion function/property is in scope unqualified inside the
// class's own instance-member bodies (`fun plus(d) = of(x + d)`
// where `of` lives on the companion). Also exercises Int/Long
// floorDiv and mod (sign-of-divisor).
class Money internal constructor(val cents: Int) {
    operator fun plus(other: Money): Money = of(cents + other.cents)
    fun dollars(): Int = cents.floorDiv(100)
    fun changeCents(): Int = cents.mod(100)
    fun doubled(): Money = of(cents * 2)
    companion object {
        fun of(c: Int): Money = Money(c)
        fun ofDollars(d: Int): Money = of(d * 100)
    }
}

fun main() {
    val a = Money.of(550)
    val b = Money.ofDollars(3)
    val sum = a + b
    println(sum.cents)
    println(sum.dollars())
    println(sum.changeCents())
    println(a.doubled().cents)
    println((-7).floorDiv(2))
    println((-7).mod(3))
    println((-7L).floorDiv(2L))
    println((-7L).mod(3L))
}
