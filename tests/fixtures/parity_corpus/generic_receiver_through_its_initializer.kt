// A local typed only by its own INITIALIZER was invisible to the receiver-type
// walk for a member or indexed receiver: that walk asked for a declared type
// and then for a call's return type, but never for the type the local's
// initializer lends it. `val xs = listOf<Base>(...)` is that shape, and every
// generic factory writes it — so the element type never reached the call on it.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun main() {
    // Explicit type argument on a factory: the written argument decides it.
    val explicitList = listOf<Base>(Derived())
    println(explicitList[0].tag())

    val explicitArray = arrayOf<Base>(Derived())
    println(explicitArray[0].tag())

    // Inferred from the elements instead.
    val inferred = listOf(Derived())
    println(inferred[0].tag())

    // Declared on the local, which always worked and must keep working.
    val declared: List<Base> = listOf(Derived())
    println(declared[0].tag())

    // Through a member call rather than an index.
    val viaFirst = listOf<Base>(Derived())
    println(viaFirst.first().tag())
}
