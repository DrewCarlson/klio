// Overload resolution ranks a candidate that binds every parameter above one
// that fills some from defaults or a vararg. The candidates make up ONE scope:
// a supertype's exact-arity overload wins over a subtype's defaulted one, even
// though the subtype is found first walking outward from the receiver.
//
// Run with: klio run examples/overload_defaults_vs_exact_arity.kt

interface Sink {
    fun write(minLength: Int = 1, maxLength: Int = 9): String
    // Declared beside it, and delegating to it — the shape a builder DSL uses.
    fun write(fixedLength: Int): String = write(fixedLength, fixedLength)
    fun tag(vararg parts: String): String = "vararg(" + parts.size + ")"
    fun tag(only: String): String = "one($only)"
}

// The subtype implements only the defaulted pair.
interface Base : Sink {
    override fun write(minLength: Int, maxLength: Int): String = "[$minLength,$maxLength]"
}

class Impl : Base

open class Widget {
    open fun draw(x: Int = 0, y: Int = 0): String = "xy($x,$y)"
}

class Fancy : Widget() {
    // An exact-arity sibling declared on the subtype.
    fun draw(only: Int): String = "only($only)"
}

fun main() {
    val s: Sink = Impl()
    // One argument: the exact-arity overload, found on the SUPERTYPE.
    println("one arg   = " + s.write(3))
    println("named     = " + s.write(fixedLength = 3))
    // Two arguments: the pair, no defaults needed.
    println("two args  = " + s.write(2, 5))
    // Zero arguments: only the defaulted candidate can bind.
    println("zero args = " + s.write())
    // A named argument that only the defaulted candidate declares.
    println("by name   = " + s.write(maxLength = 4))

    // Repeated calls must not drift: resolution is a property of the call.
    println("repeat    = " + s.write(3) + s.write(3) + s.write(3) + s.write(3))
    for (i in 1..3) print("loop$i=" + s.write(i) + " ")
    println()

    // Exact arity also outranks a vararg that could absorb the argument.
    println("vs vararg = " + s.tag("a") + " " + s.tag("a", "b") + " " + s.tag())

    // The subtype's own exact-arity sibling still wins where it applies.
    val f = Fancy()
    println("subtype   = " + f.draw(7) + " " + f.draw(1, 2) + " " + f.draw())
}
