// A plain (non-val/var) primary-constructor parameter referenced
// from a member function or property accessor is captured by the
// compiler into a synthetic field — valid Kotlin. Upstream
// kotlinx-coroutines uses this pervasively
// (CancellableContinuationImpl's `uCont`, etc.).
class Holder<T>(value: T, label: String) {
    private val stored = value
    fun show(): String = label + ":" + stored + ":" + value
}

class Acc(start: Int, private val step: Int) {
    private var cur = start
    fun next(): Int { cur += step; return cur }
    val base: Int get() = start
}

fun main() {
    println(Holder(7, "n").show())
    val a = Acc(10, 5)
    println(a.next())
    println(a.next())
    println(a.base)
}
