// Sibling vararg overloads discriminated by the Pair's SECOND component:
// a Pair<String, List<String>> argument declines the Pair<String, String>
// overload so the Iterable sibling binds. And assertEquals-style generic
// peers widen Int range literals to Long when the other side is Long.

class Sink2 {
    val flat = mutableListOf<String>()
    fun append(name: String, value: String) { flat.add("$name=$value") }
}

fun Sink2.appendAll(vararg values: Pair<String, String>): Sink2 = apply {
    for ((k, v) in values) append(k, v)
}

fun Sink2.appendAll(vararg values: Pair<String, Iterable<String>>): Sink2 = apply {
    for ((k, vs) in values) for (v in vs) append(k, v)
}

fun <T> eq(expected: T, actual: T): Boolean = expected == actual

fun main() {
    val s = Sink2()
    s.appendAll("a" to "1")
    s.appendAll("b" to listOf("2", "3"))
    println(s.flat)
    println(eq(listOf(0..10, 11..14), listOf(0L..10L, 11L..14L)))
    println("done")
}
