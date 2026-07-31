// A bare call in a receiver context is usually a member call written without
// `this.`. Inside a receiver lambda the implicit receiver is not a bound
// parameter but a CAPTURE reached through the closure's slot, which is the
// shape at most such call sites, so binding one requires materialising the
// receiver from that slot before resolving the member.
class Counter(var n: Int) {
    fun bump(by: Int): Int {
        n += by
        return n
    }

    fun label(): String = "n=" + n

    // Bare calls inside the class's own body.
    fun bumpTwice(by: Int): String {
        bump(by)
        bump(by)
        return label()
    }
}

// The extension's receiver IS a bound parameter, the other half of the shape.
fun Counter.viaExtension(): String {
    bump(1)
    return label()
}

fun main() {
    val c = Counter(0)

    // `this` is captured by the receiver lambda.
    println(c.apply {
        bump(2)
        bump(3)
    }.label())

    println(c.viaExtension())
    println(with(c) { label() })
    println(c.bumpTwice(10))

    // Nested receiver lambdas: the inner one captures through the outer.
    println(c.run {
        apply { bump(100) }
        label()
    })
}
