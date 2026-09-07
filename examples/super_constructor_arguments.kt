// Super-constructor argument forms: an object literal passes a spread
// vararg under a parameter name (`Base(ints = *ints, s = s)`), and an
// object literal's super-constructor argument may itself be an object
// literal whose own super-constructor argument closes over the enclosing
// method's receiver.
//
// Run with: klio run examples/super_constructor_arguments.kt

abstract class Base(val s: String, vararg val ints: Int)

fun spreadNamed(s: String, ints: IntArray) = object : Base(ints = *ints, s = s) {}

open class X(var s: () -> Unit)

open class Holder(val f: X) {
    fun run() {
        f.s()
    }
}

class Counter(var x: Int) {
    fun bump() {
        object : Holder(object : X({ x += 3 }) {}) {}.run()
    }
}

fun main() {
    val b = spreadNamed("OK", intArrayOf(1, 2))
    println(b.s)
    println(b.ints.joinToString(","))

    val c = Counter(1)
    c.bump()
    c.bump()
    println(c.x)
}
