// Inside `when (this) { is Wrapper -> … }` the bare name `items` is the
// smart-cast receiver's property, never the top-level `items` that shares
// its name: in the extension's own body and when the inline extension is
// spliced into a class method, whose own `this` is a different object.

val items: List<Int> = listOf(-1, -2, -3)

class Wrapper(val items: List<Int>) : Collection<Int> by items

inline fun Collection<Int>.fastSum(): Int =
    when (this) {
        is Wrapper -> items.sum()
        else -> sum()
    }

inline fun Collection<Int>.fastForEach(block: (Int) -> Unit) {
    when (this) {
        is Wrapper -> items.forEach(block)
        else -> forEach(block)
    }
}

class Ledger(val label: String) {
    val items = mutableListOf<String>()
    fun total(values: Collection<Int>): Int {
        var acc = 0
        values.fastForEach { acc += it }
        return acc + values.fastSum()
    }
}

fun main() {
    val w = Wrapper(listOf(1, 2, 3))
    println(w.fastSum())
    println(listOf(10, 20).fastSum())
    val ledger = Ledger("L")
    println(ledger.total(w))
    println(ledger.total(setOf(5, 6)))
    println(items.sum())
    println(ledger.items.size)
}
