import kotlin.jvm.JvmInline

// Value classes over numbers where the instance must be boxed: an override
// whose defaults its interface declares runs through the interface's
// defaults, a class delegating an interface `by` a value class keeps the
// instance, and a value class delegating `by` its own value keeps its
// delegate.

interface Sum {
    fun total(a: Long = 1L, b: Long = 2L): Long
}

@JvmInline
value class Base(val x: Long) : Sum {
    override fun total(a: Long, b: Long) = a + b + x
}

interface Greeter {
    fun greet(name: String): String
}

@JvmInline
value class Times(val n: Int) : Greeter {
    override fun greet(name: String): String = name.repeat(n)
}

class Polite(n: Int) : Greeter by Times(n)

@JvmInline
value class Rank(val r: Int) : Comparable<Int> by r

fun main() {
    println(Base(2).total())
    println(Base(2).total(10))
    println(Base(2).total(10, 20))
    val s: Sum = Base(3)
    println(s.total())
    println(Polite(3).greet("ab"))
    val g: Greeter = Polite(2)
    println(g.greet("x"))
    val r = Rank(14)
    println("$r ${r.compareTo(13) > 0} ${r.compareTo(14) == 0} ${r.compareTo(15) < 0}")
}
