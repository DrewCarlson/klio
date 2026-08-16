// Extensions bind against the STATIC type: an explicit type argument, a
// least-upper-bound element join, and a receiver-instantiated extension
// return all declare Base, so Base.tag() wins over the runtime Derived.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun <T> Iterable<T>.firstCopy(): T = toMutableList().removeAt(0)

fun main() {
    println(listOf<Base>(Derived()).firstCopy().tag())
    println(listOf(Derived(), Base())[0].tag())
}
