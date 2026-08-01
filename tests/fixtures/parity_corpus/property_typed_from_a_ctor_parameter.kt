// An un-annotated property initialized from a primary-constructor PARAMETER
// has that parameter's declared type. Only a constructor or factory call named
// a property's type, so this shape registered none — and it is how the stdlib's
// ranges and `Lazy` are written (`private val _start = start`), which was the
// whole of the untyped enclosing-member receivers.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

class Holder(start: Base, exact: Derived) {
    private val held = start
    private val precise = exact

    fun viaHeld(): String = held.tag()
    fun viaPrecise(): String = precise.tag()
}

fun main() {
    val h = Holder(Derived(), Derived())
    println(h.viaHeld())
    println(h.viaPrecise())
}
