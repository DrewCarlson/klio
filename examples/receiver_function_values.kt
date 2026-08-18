// Receiver-typed function VALUES: a bound member reference, a reference to a
// local function, and a receiver-lambda parameter reached through an inline
// scope function all supply their receiver the way Kotlin does. A bound
// reference already carries its receiver, so the subject becomes its
// argument; a plain function reference takes the subject in its one
// parameter; a `T.() -> Unit` parameter invoked bare inside `apply` binds the
// apply subject. A local extension function may also call itself.

interface Predicate<in T> {
    fun test(value: T): Boolean
}

object Truth : Predicate<Any?> {
    override fun test(value: Any?): Boolean = true
}

class AtLeast(private val bound: Int) : Predicate<Int> {
    override fun test(value: Int): Boolean = value >= bound
}

/** Picks the label of the first arm whose condition holds for the subject. */
class FirstMatch<in T>(private val arms: List<Pair<T.() -> Boolean, String>>) {
    fun label(value: T): String {
        for ((condition, name) in arms) {
            if (value.condition()) return name
        }
        return "none"
    }
}

class Counter {
    var total = 0
    fun add(n: Int) {
        total += n
    }
}

/** The `block` parameter keeps its receiver through `apply`'s inline body. */
fun counted(block: Counter.() -> Unit): Int = Counter().apply { block() }.total

/** A local extension function that calls itself. */
fun digitSum(n: Int): Int {
    fun Int.sum(): Int = if (this < 10) this else this % 10 + (this / 10).sum()
    return n.sum()
}

fun main() {
    val atLeast = AtLeast(10)
    val bounds = FirstMatch<Int>(
        listOf<Pair<Int.() -> Boolean, String>>(atLeast::test to "big", Truth::test to "small")
    )
    println(bounds.label(42))
    println(bounds.label(3))

    println(counted { add(2); add(40) })

    println(digitSum(98765))

    fun isEven(n: Int): Boolean = n % 2 == 0
    val parity = FirstMatch<Int>(
        listOf<Pair<Int.() -> Boolean, String>>(::isEven to "even", Truth::test to "odd")
    )
    println(parity.label(4))
    println(parity.label(7))
}
