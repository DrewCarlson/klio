// Writing a property through an unbound `KMutableProperty1` (`Class::prop`),
// where the same property is ALSO reached through a `by` delegate on a facade
// class. Both routes must land in the same backing field, and a value written
// through one must read back through the other.
//
// The two routes resolve the property name from different memory: the delegate
// route carries it as a runtime String, the direct route as an interned name.
// Whatever the write path memoizes about the first route has to stay valid for
// the second, so run this under the tracing GC too — the memo must not hold on
// to a name whose storage the collector can reclaim.
//
// Run with: klio run examples/property_ref_write_through_delegate.kt

class Contents {
    var zone: String? = null
    var label: String? = null
    fun copy(): Contents {
        val c = Contents()
        c.zone = zone
        c.label = label
        return c
    }
}

// The facade reaches `zone` through a bound property reference, so its writes
// arrive at Contents by way of the delegate's `setValue`.
class Facade(val contents: Contents = Contents()) {
    var zone: String? by contents::zone
    var label: String? by contents::label
}

// A lens over the property itself: `set` here takes the container as its first
// argument, the way a parser assigns a field it resolved by name.
class Lens<T>(private val property: kotlin.reflect.KMutableProperty1<Contents, T?>) {
    fun trySet(container: Contents, newValue: T): T? {
        val old = property.get(container)
        if (old == null) {
            property.set(container, newValue)
            return null
        }
        return old
    }

    fun read(container: Contents): T? = property.get(container)
}

val zoneLens = Lens(Contents::zone)
val labelLens = Lens(Contents::label)

// Route one, in its own scope: the facade — and the bound reference its
// delegate holds — becomes unreachable as soon as this returns.
fun seed(): String {
    val f = Facade()
    f.zone = "Europe/Berlin"
    f.label = "first"
    return "" + f.zone + "/" + f.contents.zone
}

fun main() {
    println("seeded        = " + seed())

    // Route two: a fresh container written through the property reference. The
    // earlier delegate write must not have poisoned what this one resolves to.
    val c = Contents()
    println("empty         = " + zoneLens.read(c))
    println("conflict      = " + zoneLens.trySet(c, "America/New_York"))
    println("after set     = " + zoneLens.read(c))
    println("direct read   = " + c.zone)
    println("second set    = " + zoneLens.trySet(c, "Asia/Tokyo"))
    println("unchanged     = " + c.zone)

    // A copy carries the value the reference wrote.
    println("copied        = " + c.copy().zone)

    // The other property on the same class travels the same two routes.
    println("label empty   = " + labelLens.read(c))
    println("label set     = " + labelLens.trySet(c, "second"))
    println("label read    = " + c.label)

    // Alternating routes on one container keeps a single backing field.
    val g = Facade()
    zoneLens.trySet(g.contents, "UTC")
    println("via lens      = " + g.zone)
    g.zone = "UTC+1"
    println("via facade    = " + zoneLens.read(g.contents))
}
