// A bare spread call inside an extension body binds the implicit receiver:
// `tag(*xs)` written in another `String` extension is `this.tag(*xs)`, never
// an invocation of `tag` as a receiverless value — that read the first spread
// element as the receiver and dropped `this` entirely.
//
// Run with: klio run examples/extension_spread_implicit_receiver.kt

fun String.tag(vararg xs: Int): String {
    var sum = 0
    for (x in xs) sum += x
    return this + "#" + xs.size + ":" + sum
}

fun String.viaImplicit(xs: List<Int>): String = tag(*xs.toIntArray())
fun String.viaExplicit(xs: List<Int>): String = this.tag(*xs.toIntArray())

class Wrap(val label: String) {
    fun render(vararg parts: String): String = label + parts.joinToString("|", prefix = "[", postfix = "]")
    fun viaMember(parts: Array<String>): String = render(*parts)
}

fun main() {
    println("explicit = " + "a".viaExplicit(listOf(1, 2, 3)))
    println("implicit = " + "a".viaImplicit(listOf(1, 2, 3)))
    println("member   = " + Wrap("w").viaMember(arrayOf("x", "y")))
    // An outer-scope receiver reaches a nested lambda's bare spread too.
    val fromLambda = listOf("b").map { it.viaImplicit(listOf(4, 5)) }
    println("lambda   = " + fromLambda)
}
