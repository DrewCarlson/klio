// A contract's `returns() implies (value is T)` speaks of the call's type
// argument: after `checkIs<Sub>(b)`, `b` is a `Sub`, also inside a lambda
// and after an earlier `is` check on a wider type.
import kotlin.contracts.ExperimentalContracts
import kotlin.contracts.contract

open class Base
class Sub(val x: Int) : Base()

@OptIn(ExperimentalContracts::class)
inline fun <reified T> checkIs(value: Any?): T {
    contract { returns() implies (value is T) }
    if (value !is T) throw IllegalStateException("not a " + T::class.simpleName)
    return value
}

fun check(items: List<Base>) {
    items.forEach { item ->
        if (item is Base) {
            checkIs<Sub>(item)
            println(item.x)
        }
    }
}

fun main() {
    val b: Base = Sub(3)
    checkIs<Sub>(b)
    println(b.x)
    check(listOf(Sub(4), Sub(5)))
    try {
        checkIs<Sub>(Base())
    } catch (e: IllegalStateException) {
        println(e.message)
    }
}
