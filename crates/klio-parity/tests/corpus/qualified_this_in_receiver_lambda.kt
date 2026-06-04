// `this@fn` (the enclosing extension receiver) must resolve to that receiver
// even inside a nested *receiver* lambda (`buildString { … }`, `with(x) { … }`)
// whose own `this` is a different (builtin) receiver. Inside
// `fun String.tagged()`, the `buildString { … this@tagged … }` body must see
// the String, not the StringBuilder. ktor's `String.encodeURLParameter() =
// buildString { … encode(this@encodeURLParameter) … }` depends on this.
fun String.tagged(): String = buildString {
    append("[")
    append(this@tagged)
    append("](len=")
    append(this@tagged.length.toString())
    append(")")
}

fun String.wrapWith(): String = with(StringBuilder()) {
    append(this@wrapWith.uppercase())
    append("/")
    append(this@wrapWith.reversed())
    toString()
}

fun main() {
    println("abc".tagged())
    println("Hi".wrapWith())
}
