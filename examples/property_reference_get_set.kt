// A property reference reads and writes through its `get`/`set` members: an
// unbound `T::prop` takes the target first, a bound `x::prop` uses its
// captured receiver, and references carried in a list drive both — the
// reflection surface a table-driven test uses to poke every field.
//
// Run with: klio run examples/property_reference_get_set.kt

import kotlin.reflect.KMutableProperty1

class Settings {
    var volume: Int = 5
    var name: String = "default"
}

class FieldAndValue<T, V>(val property: KMutableProperty1<T, V>, val value: V) {
    fun apply(target: T) {
        property.set(target, value)
    }
}

fun main() {
    val s = Settings()

    val unbound = Settings::volume
    unbound.set(s, 11)
    println("unbound set = " + s.volume)
    println("unbound get = " + unbound.get(s))

    val bound = s::name
    bound.set("loud")
    println("bound set   = " + s.name)
    println("bound get   = " + bound.get())

    // Table-driven writes through a generic local class.
    val fields = listOf<FieldAndValue<Settings, *>>(
        FieldAndValue(Settings::volume, 42),
        FieldAndValue(Settings::name, "table"),
    )
    for (f in fields) f.apply(s)
    println("table       = " + s.volume + "/" + s.name)
}
