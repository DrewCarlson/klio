// An inner class of a supertype constructs through `super.Inner(args)`,
// through a bare `Inner(args)` in the subclass, through an explicit outer
// instance, and from an extension on the outer type; each carries the
// outer instance it was built through.
open class A(val value: String) {
    inner class B(val s: String) {
        val result = value + "_" + s
    }
}

class C : A("fromC") {
    fun classReceiver() = B("x")
    fun superReceiver() = super.B("y")
    fun otherReceiver() = A("fromA").B("z")
    fun A.viaExtension() = this.B("w")
    fun extReceiver() = A("ext").viaExtension()
}

fun main() {
    val c = C()
    println(c.classReceiver().result)
    println(c.superReceiver().result)
    println(c.otherReceiver().result)
    println(c.extReceiver().result)
}
