// A member extension declared in an interface default, a superclass, or
// the class itself is visible wherever an enclosing `this` carries that
// owner anywhere in its supertype closure: through an inner class's outer
// links at any depth, inside a lambda, and inside `with`, where the
// innermost applicable receiver wins (`5.scaled()` scales by `other`'s
// factor, the `tagged` outside the block still tags with `this@Outer`'s).
// Two local classes sharing a name resolve their own extensions, and
// data-class members work on local and hand-written hierarchies alike.
interface Scaled {
    val factor: Int
    fun Int.scaled(): Int = this * factor
}

abstract class Base(override val factor: Int) : Scaled {
    fun String.tagged(): String = "[$this:$factor]"
}

class Outer(factor: Int) : Base(factor) {
    inner class Inner(val n: Int) {
        fun render(): String = n.scaled().toString().tagged()
        inner class Deep {
            fun render(): String = (n + 1).scaled().toString().tagged()
        }
    }
    fun viaLambda(): String = listOf(1, 2, 3).joinToString(",") { it.scaled().toString() }.tagged()
    fun viaWith(other: Outer): String = with(other) { 5.scaled().toString() }.tagged()
}

fun first(): String {
    class Local(val k: Int) {
        fun Int.twice(): Int = this * 2 * k
        fun go(): Int = 3.twice()
    }
    return Local(1).go().toString()
}

fun second(): String {
    class Local(val k: Int) {
        fun Int.twice(): Int = this + k
        fun go(): Int = 3.twice()
    }
    return Local(10).go().toString()
}

fun third(): String {
    data class L(val v: Int)
    return (L(1) == L(1)).toString() + L(2)
}

data class Pt(val x: Int, val y: Int)
open class Shape(val name: String) {
    override fun toString() = "Shape($name)"
}
class Sq(val side: Int) : Shape("sq") {
    override fun equals(other: Any?) = other is Sq && other.side == side
    override fun hashCode() = side
}

fun main() {
    val o = Outer(3)
    val i = o.Inner(4)
    println(i.render())
    println(i.Deep().render())
    println(o.viaLambda())
    println(o.viaWith(Outer(7)))
    repeat(2) { println(first() + " " + second()) }
    println(Pt(1, 2) == Pt(1, 2))
    println(Pt(1, 2))
    println(setOf(Pt(1, 2), Pt(1, 2)).size)
    println(Sq(2) == Sq(2))
    println(Sq(2))
    println(Sq(2).hashCode())
    println(third())
}
