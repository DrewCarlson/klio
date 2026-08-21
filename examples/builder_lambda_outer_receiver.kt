// A builder lambda's bare call still sees the enclosing EXTENSION receiver:
// `consumeEach(::add)` inside `buildList { }` written in a `Source` extension
// binds `this@collect` (the source) for `consumeEach` and the MutableList for
// `add` — the closure's lexical receiver chain includes the creating
// function's own receiver, and an extension declared on the outer receiver's
// interface proves through the runtime subtype walk.
//
// Run with: klio run examples/builder_lambda_outer_receiver.kt

interface Source {
    val items: List<Int>
}

class ListSource(override val items: List<Int>) : Source

fun Source.consumeAll(action: (Int) -> Unit) {
    for (e in items) action(e)
}

fun Source.collect(): List<Int> = buildList {
    consumeAll(::add)
}

fun Source.collectDoubled(): List<Int> = buildList {
    consumeAll { add(it * 2) }
}

fun main() {
    println("refs    = " + ListSource(listOf(1, 2, 3)).collect())
    println("lambda  = " + ListSource(listOf(4, 5)).collectDoubled())
    // A nested builder keeps both receivers reachable.
    val nested = ListSource(listOf(7)).run {
        buildList {
            consumeAll(::add)
            add(99)
        }
    }
    println("nested  = " + nested)
}
