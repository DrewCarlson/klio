// A bare top-level stdlib function call (`listOf`, `setOf`, `mapOf`, …)
// inside a receiver lambda (`with(r) { … }`, `buildString { … }`) must bind
// the top-level function and apply its arguments — not be mistaken for a
// property of the lambda's receiver. The receiver-lambda lowering probes
// `get_field(receiver, "listOf")` first; resolving that to the
// `kotlin.collections.listOf` function and auto-invoking it as a one-arg
// property getter produced a collection the call site then tried to invoke
// (`call_value on List`). ktor's `Codecs` builds sets this way inside
// `buildString { … }`.
fun main() {
    println(with(StringBuilder()) { listOf(1, 2, 3).size })
    println(buildString { append(listOf("a", "b").size) })
    println(with(0) { setOf(9, 9, 7).size })
    println(with("ignored") { mapOf("k" to 1, "j" to 2).size })
    val joined = buildString {
        listOf("x", "y", "z").forEach { append(it) }
    }
    println(joined)
}
