// Kotlin infers a type parameter from every constraint together — the
// receiver, each value argument, each element. The binding demanded EQUALITY
// across constraints, so a second one that the first already subsumed
// (`getOrDefault(k, Derived())` on a Map of Base, `listOf(Derived(), base)`)
// rejected the whole instantiation and left the call site untyped. Extensions
// bind against the STATIC type, which is where that shows. getOrDefault also
// had no declaration at all: on the JVM it is a member of the Map builtin,
// which the compiled common surface never declares.
open class Base
class Derived : Base()

fun Base.tag(): String = "base"
fun Derived.tag(): String = "derived"

fun main() {
    // The receiver binds V; the value argument is a subtype of it.
    val m = mutableMapOf<String, Base>()
    println(m.getOrDefault("k", Derived()).tag())

    // Declared as the base interface: the exact pattern head.
    val exact: Map<String, Base> = m
    println(exact.getOrDefault("k", Derived()).tag())

    // A later constraint that subsumes the earlier one widens the binding,
    // and a later one the binding subsumes leaves it alone.
    val mixed = listOf(Derived(), Base())
    println(mixed[0].tag())
    val mixedRev = listOf(Base(), Derived())
    println(mixedRev[1].tag())

    // A null value for a present key is returned as-is, as on the JVM.
    val nullable: MutableMap<String, Base?> = mutableMapOf()
    nullable["k"] = null
    println(nullable.getOrDefault("k", Derived()) == null)
    println(nullable.getOrDefault("x", Derived()) == null)
}
