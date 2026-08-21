interface Sink { fun emit(v: Int) }

fun Sink.emitAll(xs: List<Int>) { for (x in xs) emit(x) }

fun build(block: Sink.() -> Unit): List<Int> {
    val out = ArrayList<Int>()
    object : Sink { override fun emit(v: Int) { out.add(v) } }.block()
    return out
}

// NOT inline: the lambda argument stays a real closure.
fun eachOf(xs: List<List<Int>>, action: (List<Int>) -> Unit) { for (x in xs) action(x) }

fun main() {
    val nested = listOf(listOf(1, 2), listOf(3))
    // A nested closure inside a receiver lambda: `emitAll` needs the OUTER
    // lambda's receiver, not the outer lambda itself.
    println("nested = " + build { eachOf(nested) { v -> emitAll(v) } })
    println("member = " + build { eachOf(nested) { v -> emit(v.size) } })
    println("flat   = " + build { emitAll(nested[0]) })
}
