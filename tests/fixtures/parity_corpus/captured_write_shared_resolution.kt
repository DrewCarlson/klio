inline fun Int.forEachOneBit(body: (mask: Int, index: Int) -> Unit) {
    var remaining = this
    var index = 0
    while (remaining != 0) {
        val bit = remaining and -remaining
        body(bit, index++)
        remaining = remaining xor bit
    }
}

open class CounterBase {
    fun forEachValue(body: (Int) -> Unit) {
        body(1)
        body(2)
    }

    inline fun forEachInlineValue(body: (Int) -> Unit) {
        body(2)
        body(3)
    }
}

class Counter : CounterBase() {
    fun inheritedMemberTotal(): Int {
        var total = 0
        forEachValue { total += it }
        return total
    }

    fun inheritedInlineMemberTotal(): Int {
        var total = 0
        forEachInlineValue { total += it }
        return total
    }

    fun infixReceiverTotal(mask: Int): Int {
        var total = 0
        (7 and mask).forEachOneBit { bit, _ -> total += bit }
        return total
    }
}

class Scope(val base: Int)

fun Scope.applyValue(body: (Int) -> Unit) {
    body(base)
}

fun implicitReceiverExtensionTotal(scope: Scope): Int {
    var total = 0
    with(scope) {
        applyValue { total += it }
    }
    return total
}

class CallableHolder(private val run: CallableHolder.((Int) -> Unit) -> Unit) {
    fun total(): Int {
        var total = 0
        run { total += it }
        return total
    }
}

class Bits(val value: Int) {
    infix fun merge(other: Bits): Bits = Bits(value or other.value)

    fun forEachBit(body: (Int) -> Unit) {
        value.forEachOneBit { bit, _ -> body(bit) }
    }
}

@Suppress("EXTENSION_SHADOWED_BY_MEMBER")
infix fun Bits.merge(other: Bits): Int = -1

fun userInfixReceiverTotal(): Int {
    var total = 0
    (Bits(1) merge Bits(4)).forEachBit { total += it }
    return total
}

fun consume(body: (Int) -> Unit) {
    body(4)
}

class VarargScope

fun VarargScope.choose(vararg values: Int): String = "extension:${values.size}"

fun choose(value: Int): String = "global:$value"

fun VarargScope.chooseImplicitly(): String = choose(1)

fun main() {
    val counter = Counter()
    println(counter.inheritedMemberTotal())
    println(counter.inheritedInlineMemberTotal())
    println(counter.infixReceiverTotal(6))
    println(implicitReceiverExtensionTotal(Scope(17)))
    println(CallableHolder { block -> block(7) }.total())
    println(userInfixReceiverTotal())

    var topLevelTotal = 1
    consume { topLevelTotal += it }
    println(topLevelTotal)
    println(VarargScope().chooseImplicitly())
}
