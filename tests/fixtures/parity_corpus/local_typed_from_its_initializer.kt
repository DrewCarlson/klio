// A local's declared type is its initializer's type — Kotlin infers `val x =
// f()` as `f`'s return type, and a `var`'s later assignment must conform to it,
// so the initializer's type is the local's type at every use. A CONSTRUCTOR
// initializer names its own type directly; those reach the dispatch census as
// `no_func`, because the callee resolves to a class rather than to a function.
class Box(val label: String) {
    fun describe(): String = "box:" + label
    fun retag(s: String): Box = Box(label + s)
}

open class Node(val n: Int) {
    open fun weight(): Int = n
}

class Heavy(n: Int) : Node(n) {
    override fun weight(): Int = n * 10
}

fun makeBox(): Box = Box("made")

fun main() {
    // Constructor initializer.
    val b = Box("a")
    println(b.describe())
    println(b.retag("!").describe())

    // Return-type initializer.
    val m = makeBox()
    println(m.describe())

    // A `var` keeps the declared type across reassignment, and the member call
    // still dispatches to the runtime class.
    var node = Node(2)
    println(node.weight())
    node = Heavy(2)
    println(node.weight())

    // A subtype initializer types the local as the subtype.
    val h = Heavy(3)
    println(h.weight())

    // Chained through another typed local.
    val chained = b.retag("?")
    println(chained.describe())
}
