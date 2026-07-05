import kotlin.reflect.KProperty

class Data(val s: String, var n: Int)

val d = Data("hello", 1)
var top = 5

val Data.extVal by d::s
var Data.extVar by ::top

class Loud {
    operator fun getValue(thisRef: Any?, property: KProperty<*>): String = "loud:${property.name}"
}

val Data.extLoud by Loud()

fun main() {
    val local = Data("x", 2)
    println(local.extVal)
    local.extVar = 7
    println(top)
    println(local.extVar)
    println(local.extLoud)
    refs()
}

fun refs() {
    val local = Data("y", 3)
    val r = local::extVal
    println(r.get())
    println(r.name)
}
