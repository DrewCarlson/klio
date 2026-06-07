// An `inner class` method may call a method / read a property of its
// enclosing class instance. When the normal lowering can't bind it,
// the dispatch must fall back along the receiver's captured `outer`
// link (call-side and field-side), including through two nesting
// levels.
class Outer(private val base: Int) {
    private fun scale(n: Int): Int = n * base

    inner class Mid(private val k: Int) {
        fun midValue(): Int = scale(k) + base

        inner class Leaf(private val z: Int) {
            // reaches Outer.scale (two levels up) and Outer.base
            fun leafValue(): Int = scale(z) + base
        }

        fun leaf(z: Int): Leaf = Leaf(z)
    }

    fun run(): String {
        val m = Mid(3)
        val l = m.leaf(5)
        return "${m.midValue()} ${l.leafValue()}"
    }
}

fun main() {
    println(Outer(10).run())
}
