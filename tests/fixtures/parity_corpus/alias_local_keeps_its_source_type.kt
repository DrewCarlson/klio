// `val b = a` gives `b` whatever type `a` has. Only a source local with a
// DECLARED type passed it on, so a local typed by its own initializer instead
// — a property read, an indexed read, a call — handed the alias nothing, and
// the chain broke at the first rename. Extensions bind against the STATIC
// type, which is where that shows.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

class Holder {
    val item: Base = Derived()
}

fun makeBase(): Base = Derived()

fun main() {
    val h = Holder()

    // Source typed by a property-read initializer, not by a declaration.
    val first = h.item
    val second = first
    println(second.tag())

    // Source typed by a call's return type.
    val made = makeBase()
    val alias = made
    println(alias.tag())

    // Two renames deep.
    val again = alias
    println(again.tag())

    // A declared source still wins, and an exact one stays exact.
    val exact: Derived = Derived()
    val exactAlias = exact
    println(exactAlias.tag())
}
