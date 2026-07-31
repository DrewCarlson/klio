// An indexed read and an arithmetic operator are member calls with a declared
// return type — `a[i]` is `a.get(i)`, `a * b` is `a.times(b)`. Only `plus` and
// `minus` lent their result type to a receiver, and indexing lent nothing at
// all, so the value read out of a container arrived untyped. Extensions bind
// against the STATIC type, which is where that shows.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

class Row(private val cells: List<Base>) {
    operator fun get(i: Int): Base = cells[i]
}

class Scale(val n: Int) {
    operator fun times(other: Int): Base = Derived()
    operator fun rangeTo(other: Scale): Base = Derived()
}

fun main() {
    val row = Row(listOf(Derived(), Derived()))
    println(row[0].tag())
    val held = row[1]
    println(held.tag())

    println((Scale(2) * 3).tag())
    println((Scale(1)..Scale(2)).tag())

    // A declared element type still reads through the container's own `get`.
    val exact: List<Derived> = listOf(Derived())
    println(exact[0].tag())
}
