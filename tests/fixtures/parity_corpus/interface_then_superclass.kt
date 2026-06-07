// A class may list interfaces before its superclass; the `super(...)` args
// belong to the superclass, not the (ctor-less) interface.
interface Marker
interface Tagged { val tag: String }

open class Base(val flag: Boolean, val data: String) {
    val computed: String = if (flag) "Y:$data" else "N:$data"
}

class A(d: String) : Marker, Base(true, d)
class B(d: String) : Marker, Tagged, Base(false, d) {
    override val tag: String get() = "B"
}
class C(d: String) : Base(true, d)   // no interface (control)

fun main() {
    println(A("x").computed)   // Y:x
    println(A("x").flag)       // true
    println(B("y").computed)   // N:y
    println(B("y").tag)        // B
    println(C("z").computed)   // Y:z
}
