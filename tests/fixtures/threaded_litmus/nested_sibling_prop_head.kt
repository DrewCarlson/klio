//> bytes:4 number:6
//> HexPair(upper=false)
// A property typed by a QUALIFIED nested class (`Bytes.Builder`) must keep
// its dotted head: recording only `Builder` made the scoped resolution bind
// the enclosing `Pair.Builder` and run its build() against a Bytes.Builder
// instance. Sibling nested classes referenced by bare name inside the
// enclosing class resolve through the classifier chain.
class HexPair internal constructor(val upper: Boolean, val bytes: Bytes, val number: Number2) {
    class Bytes internal constructor(val perLine: Int) {
        class Builder internal constructor() {
            var perLine: Int = 4
            fun build(): Bytes = Bytes(perLine)
        }
    }

    class Number2 internal constructor(val minLength: Int) {
        class Builder internal constructor() {
            var minLength: Int = 6
            fun build(): Number2 = Number2(minLength)
        }
    }

    class Builder internal constructor() {
        var upper: Boolean = false
        val bytes: Bytes.Builder = Bytes.Builder()
        val number: Number2.Builder = Number2.Builder()
        fun build(): HexPair = HexPair(upper, bytes.build(), number.build())
    }

    override fun toString(): String = "HexPair(upper=$upper)"
}

fun main() {
    val p = HexPair.Builder().build()
    println("bytes:${p.bytes.perLine} number:${p.number.minLength}")
    println(p)
}
