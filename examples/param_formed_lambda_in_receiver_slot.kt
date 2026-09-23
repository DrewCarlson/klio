// Kotlin lets a `(T) -> Unit` literal stand where a `T.() -> Unit` parameter is
// declared, so the subject plays both roles. One forwarding hop hides that: the
// literal is written against the param form, handed on, and spliced into the
// receiver form, where its `it` has no argument to bind to.
//
// Run with: klio run examples/param_formed_lambda_in_receiver_slot.kt

class Box(val items: MutableList<Int>)

inline fun Box.mutate(mutator: (MutableList<Int>) -> Unit): List<Int> =
    items.apply(mutator).toList()

inline fun Box.mutateNamed(mutator: (MutableList<Int>) -> Unit): List<Int> =
    items.apply(mutator).toList()

// A receiver-form literal in the same slot keeps `this`, and takes no `it` of
// its own: the `it` here is the enclosing lambda's.
fun outerItKeepsItsOwner(): List<String> =
    listOf("a", "b").map { StringBuilder().apply { append(it) }.toString() }

fun main() {
    val extra = listOf(7, 8)
    println(Box(mutableListOf(1, 2)).mutate { it.addAll(extra) })
    println(Box(mutableListOf(3)).mutateNamed { list -> list.add(4) })
    println(outerItKeepsItsOwner())
}
