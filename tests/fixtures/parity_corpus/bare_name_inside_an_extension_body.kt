// A bare name in an extension's body is a member of the EXTENSION RECEIVER
// written without `this.`. The search for its declared type started at the
// enclosing class, and a top-level extension has none, so the name got no type
// at all — which is the shape the unsigned array classes are written in
// (`val UByteArray.indices get() = storage.indices`).
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

class Cell(val held: Base, val exact: Derived)

// Top-level extension: no enclosing class, so `held` is the receiver's.
fun Cell.viaHeld(): String = held.tag()

fun Cell.viaExact(): String = exact.tag()

// An inherited property reaches through the receiver's supertype chain too.
open class Holder(val held: Base)
class SubHolder(held: Base) : Holder(held)

fun SubHolder.viaInherited(): String = held.tag()

fun main() {
    val c = Cell(Derived(), Derived())
    println(c.viaHeld())
    println(c.viaExact())
    println(SubHolder(Derived()).viaInherited())
}
