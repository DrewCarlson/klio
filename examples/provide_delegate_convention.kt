// A delegated property first offers its delegate expression the
// `provideDelegate(thisRef, property)` call: when a member or extension
// operator applies, the property delegates to its result; otherwise the
// expression's value is the delegate. The convention runs once, at the
// declaration, for local, top-level and member properties alike, and every
// read then goes through `getValue` (a local delegate is never read at its
// declaration).
import kotlin.reflect.KProperty

var log = ""

class Named(val label: String) {
    operator fun getValue(thisRef: Any?, property: KProperty<*>): String {
        log += "get(${property.name});"
        return label
    }
}

class Provider(val label: String) {
    operator fun provideDelegate(thisRef: Any?, property: KProperty<*>): Named {
        log += "provide(${property.name}@${thisRef?.let { it::class.simpleName } ?: "top"});"
        return Named(label)
    }
}

operator fun String.provideDelegate(thisRef: Any?, property: KProperty<*>): Named {
    log += "provide-ext(${property.name});"
    return Named(this)
}

class Holder {
    val member by Provider("m")
    val viaString by "s"
}

val topLevel by Provider("t")

fun main() {
    val local by Provider("l")
    val plain by Named("p")
    log += "declared;"
    println(local + plain)
    println(topLevel)
    val h = Holder()
    println(h.member + h.viaString)
    println(log)
}
