// Instance, companion, and overloaded methods honour default
// parameters when the caller omits trailing args — the same padding
// top-level functions already get. A defaulted call must also pick
// the right overload (fewer args + all-trailing-defaulted).
class Calc(val base: Int) {
    fun add(x: Int, y: Int = 10): Int = x + y + base
    fun blockForm(x: Int, step: Int = 2): Int {
        var acc = base
        repeat(x) { acc += step }
        return acc
    }
}

class Box internal constructor(val v: Long) {
    companion object {
        val MIN: Box = Box(-1)
        val MAX: Box = Box(999)
        fun make(s: Long, adj: Long = 0): Box {
            val t = s + adj
            return when {
                t < 0 -> MIN
                t > 999 -> MAX
                else -> Box(t)
            }
        }
        fun make(s: Long, adj: Int): Box = make(s, adj.toLong())
    }
}

fun main() {
    val c = Calc(100)
    println(c.add(5, 2))
    println(c.add(5))
    println(c.blockForm(3))
    println(c.blockForm(3, 5))
    println(Box.make(5L).v)
    println(Box.make(5L, 3).v)
    println(Box.make(5L, 3L).v)
    println(Box.make(-100L, 0).v)
    println(Box.make(10_000L, 0).v)
}
