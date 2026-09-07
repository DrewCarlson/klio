// A local class named like the enclosing class shadows it inside the
// function: `B(11)` constructs the local `B`, and a member inherited from
// the local class's superclass dispatches through the local declaration,
// not through the same-named enclosing class.
//
// Run with: klio run examples/local_class_name_shadowing.kt

open class C(val s: Int) {
    fun test() = "C.test($s)"
}

class B(var x: Int) {
    fun foo(): String {
        class B(val a: Int) : C(a * 2)
        val local = B(11)
        return local.test() + " a=" + local.a
    }

    fun describe() = "outer B(x=$x)"
}

fun main() {
    val b = B(1)
    println(b.foo())
    println(b.describe())
}
