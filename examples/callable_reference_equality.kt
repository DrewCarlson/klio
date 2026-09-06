// Callable references compare by what they refer to, never by object
// identity: two references to the same top-level function are equal (and
// hash equal) though they are distinct objects; a class-qualified
// reference equals another to the same member; a bound reference equals
// one bound to an equal receiver and differs from one bound to another
// receiver or from the unbound form. A reference adapted to a function
// type (defaults dropped, a vararg spread, a result coerced to Unit) is a
// distinct callable per adaptation: equal to the same adaptation taken
// elsewhere, different from another adaptation of the same target.
class V(val id: Int) {
    fun m(): String = "m$id"
    override fun equals(other: Any?) = other is V && other.id == id
    override fun hashCode() = id
}

fun f(): String = "f"
fun target(x: Int, y: String = "", z: String = ""): Int = x
fun join(vararg parts: String): String = parts.joinToString("+")

fun take3(fn: (Int, String, String) -> Unit): Any = fn
fun take2(fn: (Int, String) -> Unit): Any = fn
fun take2Value(fn: (Int, String) -> Int): Any = fn
fun takeTwoStrings(fn: (String, String) -> String): Any = fn
fun takeArray(fn: (Array<String>) -> String): Any = fn

fun main() {
    println(::f == ::f)
    println(::f === ::f)
    println(::f.hashCode() == ::f.hashCode())
    println(V::m == V::m)

    val a = V(1)
    val b = V(1)
    val c = V(2)
    println(a::m == a::m)
    println(a::m == b::m)
    println(a::m == c::m)
    println((a::m as Any) == (V::m as Any))
    println(a::m.hashCode() == b::m.hashCode())

    println(take3(::target) == take3(::target))
    println(take3(::target).hashCode() == take3(::target).hashCode())
    println(take3(::target) == take2(::target))
    println(take2(::target) == take2Value(::target))
    println(takeTwoStrings(::join) == takeTwoStrings(::join))
    println(takeTwoStrings(::join) == takeArray(::join))
    println(::f == "f")
    println(::f.equals(42))
}
