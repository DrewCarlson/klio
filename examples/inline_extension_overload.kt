// Overloaded inline extension functions selected by argument type.
//
// Two extensions share a receiver and an argument count, differing only in the
// parameter's type. A call has to pick by that type. When the call is written
// bare — with the receiver implicit, from inside a member — the inline splice
// path sees only the call's *shape* (how many arguments, is the last a
// lambda), and shape cannot separate these two. Splicing either one would be a
// guess, so the call falls through to normal dispatch, which ranks by argument
// type.
//
// androidx.collection hits exactly this: `ArraySet.addAll(Collection)` calls a
// bare `addAllInternal(elements)`, and the sibling overload takes an ArraySet.
//
// Run with: klio run examples/inline_extension_overload.kt

class Bag<E> {
    val items = ArrayList<E>()
    var chosen = "none"

    // Bare calls: the receiver is implicit.
    fun addAll(other: Bag<out E>) {
        addAllInternal(other)
    }

    fun addAll(elements: Collection<E>): Boolean = addAllInternal(elements)
}

internal inline fun <E> Bag<E>.addAllInternal(other: Bag<out E>) {
    chosen = "Bag"
    for (i in other.items) items.add(i)
}

internal inline fun <E> Bag<E>.addAllInternal(elements: Collection<E>): Boolean {
    chosen = "Collection"
    return items.addAll(elements)
}

fun main() {
    val fromList = Bag<String>()
    println("list: added=${fromList.addAll(listOf("a", "b"))} via=${fromList.chosen} size=${fromList.items.size}")

    val fromSet = Bag<String>()
    fromSet.addAll(setOf("x"))
    println("set: via=${fromSet.chosen} size=${fromSet.items.size}")

    // The receiver-typed overload still wins for a receiver-typed argument.
    val fromBag = Bag<String>()
    fromBag.addAll(fromList)
    println("bag: via=${fromBag.chosen} size=${fromBag.items.size}")

    // The same call with an explicit receiver resolves identically.
    val explicit = Bag<String>()
    explicit.addAllInternal(listOf("p", "q"))
    println("explicit: via=${explicit.chosen} size=${explicit.items.size}")
}
