// A property with no declared type takes its type from its initializer. A
// CONSTRUCTOR call named it; a factory call did not, so `val made = newBase()`
// left the property with no registered type head and reads through it bound
// against the runtime class instead of the declared one. Extensions resolve
// against the STATIC type, which is where that shows.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun newBase(): Base = Derived()
fun newDerived(): Derived = Derived()

class Holder {
    val made = newBase()
    val exact = newDerived()
    val built = Derived()
}

fun main() {
    val h = Holder()
    println(h.made.tag())
    println(h.exact.tag())
    println(h.built.tag())
}
