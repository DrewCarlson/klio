import kotlin.reflect.KMutableProperty1

class Inner { var tz: String? = null }

// A facade that DELEGATES a same-named property to the inner object.
class Outer(val inner: Inner = Inner()) {
    var tz: String? by inner::tz
}

class Accessor<O, F>(val property: KMutableProperty1<O, F?>) {
    fun set(c: O, v: F) { property.set(c, v) }
    fun get(c: O): F? = property.get(c)
}

val innerField = Accessor(Inner::tz)

fun main() {
    // Touch the delegated property first, as the real code does (format then parse).
    val o = Outer()
    o.tz = "Europe/Berlin"
    println("outer.tz = " + o.tz)

    // Now write the SAME-NAMED property on the inner class through an unbound reference.
    val fresh = Inner()
    innerField.set(fresh, "America/New_York")
    println("inner via accessor = " + innerField.get(fresh) + " direct = " + fresh.tz)
}
