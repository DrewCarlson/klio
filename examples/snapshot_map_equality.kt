// Structural equality of the Compose-vendored persistent maps: content
// equality is insertion-order independent (including hash-colliding
// string keys), one changed value or a missing key breaks it, and
// user-defined equals on keys/values still dispatches.
import androidx.compose.runtime.mutableStateMapOf

data class K(val n: Int)
class ModEq(val n: Int) {
    override fun equals(other: Any?) = other is ModEq && other.n % 10 == n % 10
    override fun hashCode() = n % 10
}

fun main() {
    val a = mutableStateMapOf(1 to "x", 2 to "y", 3 to "z")
    val b = mutableStateMapOf(3 to "z", 1 to "x", 2 to "y")
    println("reordered=${a.toMap() == b.toMap()}")
    val c = mutableStateMapOf(1 to "x", 2 to "y", 3 to "DIFF")
    println("valueDiff=${a.toMap() == c.toMap()}")
    val d = mutableStateMapOf(1 to "x", 2 to "y")
    println("missingKey=${a.toMap() == d.toMap()}")
    val e = mutableStateMapOf("Aa" to 1, "BB" to 2, "other" to 3)
    val f = mutableStateMapOf("BB" to 2, "other" to 3, "Aa" to 1)
    println("collidingKeys=${e.toMap() == f.toMap()}")
    val g = mutableStateMapOf("Aa" to 1, "BB" to 99, "other" to 3)
    println("collidingDiff=${e.toMap() == g.toMap()}")
    val h = mutableStateMapOf(K(1) to ModEq(5))
    val i = mutableStateMapOf(K(1) to ModEq(15))
    println("customEqualsSame=${h.toMap() == i.toMap()}")
    val j = mutableStateMapOf(K(1) to ModEq(6))
    println("customEqualsDiff=${h.toMap() == j.toMap()}")
    val w1 = mutableStateMapOf<Int, Int>(); val w2 = mutableStateMapOf<Int, Int>()
    for (n in 0 until 1000) { w1[n] = n * 7 }
    for (n in 999 downTo 0) { w2[n] = n * 7 }
    println("wideEqual=${w1.toMap() == w2.toMap()}")
    w2[500] = -1
    println("wideOneDiff=${w1.toMap() == w2.toMap()}")
    println("selfEqual=${w1.toMap() == w1.toMap()}")
}
