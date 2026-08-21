import kotlin.reflect.KMutableProperty0
import kotlin.reflect.KProperty

class Contents { var n: Int? = null }

private class TwoDigit(private val reference: KMutableProperty0<Int?>) {
    operator fun getValue(thisRef: Any?, property: KProperty<*>) = reference.getValue(thisRef, property)
    operator fun setValue(thisRef: Any?, property: KProperty<*>, value: Int?) {
        require(value === null || value in 0..99) { "${property.name} must be two digits, got '$value'" }
        reference.setValue(thisRef, property, value)
    }
}

class Facade(val c: Contents = Contents()) {
    var n: Int? by TwoDigit(c::n)
}

fun main() {
    val f = Facade()
    f.n = 5
    println("direct = " + f.n)
    val p = Facade::n
    println("get    = " + p.get(f))
    p.set(f, 43)
    println("set    = " + p.get(f))
    try { p.set(f, 100) } catch (e: IllegalArgumentException) { println("reject = " + e.message) }
    p.set(f, null)
    println("null   = " + p.get(f))
}
