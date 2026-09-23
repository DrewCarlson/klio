// A property declared in a class body is read from its layout slot, the same
// as a constructor property — but only where the slot is the class's own. An
// INHERITED body slot can be replaced by an accessor in any class between, and
// the layout records the cell, not the replacement: `Square` overrides
// `Shape`'s stored `sides` with a getter and contributes no cell of its own, so
// the inherited slot still holds the base's value.
//
// Run with: klio run examples/body_property_slot_read.kt

class Counter {
    val start = 7
    var seen = 0
    val doubled get() = start * 2
    fun bump(): Int {
        seen = seen + 1
        return seen
    }
}

open class Shape {
    open val sides: Int = 0
}

class Square : Shape() {
    override val sides: Int get() = 4
}

class Pentagon : Shape()

fun readSides(s: Shape): Int = s.sides

fun main() {
    val c = Counter()
    println("start=${c.start} doubled=${c.doubled}")
    c.bump()
    c.bump()
    println("seen=${c.seen}")
    // Read through the declared type, where the slot is the base's.
    println("square=${readSides(Square())} pentagon=${readSides(Pentagon())}")
    // Read through the exact type, where the override is visible.
    println("square direct=${Square().sides} base direct=${Shape().sides}")
}
