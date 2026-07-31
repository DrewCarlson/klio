// A bodyless member header is settled by its OWN class's implementation.
// `kotlin.Double.equals` and `kotlin.String.equals` share the package `kotlin`
// and the simple name `equals`, and the bare-name map carries `equals` to the
// package-level string form. Either edge settles the Double header with the
// String implementation, which then rejects the receiver it is handed
// ("String.equals requires a String receiver, got 0.0"). Both were reachable
// only once these members bound to a virtual slot.
fun main() {
    val d: Double = 0.0
    println(d.equals(0.0))
    println(d.equals(1.0))
    println(d.equals("0.0"))

    val i: Int = 7
    println(i.equals(7))
    println(i.equals(8))

    val c: Char = 'x'
    println(c.equals('x'))

    val b: Boolean = true
    println(b.equals(true))

    // The string form still resolves for a string receiver.
    val s: String = "ab"
    println(s.equals("ab"))
    println(s.equals("AB"))
    println(s.equals("AB", ignoreCase = true))

    // Comparison through a supertype-typed receiver goes through the same slot.
    val any: Any = 0.0
    println(any.equals(0.0))
    println(any == d)
}
