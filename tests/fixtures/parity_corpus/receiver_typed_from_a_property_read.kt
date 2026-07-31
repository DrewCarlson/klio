// A local initialized from a property read carries the property's declared
// type. Only calls, literals and templates were recorded as initializers, so
// `val x = h.item` left the local with no static type at all — and an
// extension binds against the STATIC type, which is where that shows.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

class Holder {
    val item: Base = Derived()
    val exact: Derived = Derived()
}

fun main() {
    val h = Holder()

    val fromDeclared = h.item
    println(fromDeclared.tag())

    val fromExact = h.exact
    println(fromExact.tag())

    // Direct, for comparison: the same two reads without the local.
    println(h.item.tag())
    println(h.exact.tag())
}
