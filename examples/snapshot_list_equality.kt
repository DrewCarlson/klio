// Structural equality of Compose snapshot-state lists across both
// persistent-vector representations (small buffer and trie), including
// null elements, single-element differences at either end, and
// user-defined equals still dispatching.
import androidx.compose.runtime.mutableStateListOf

class ModEq(val n: Int) {
    override fun equals(other: Any?) = other is ModEq && other.n % 10 == n % 10
    override fun hashCode() = n % 10
}

fun main() {
    val s1 = mutableStateListOf(1, 2, 3)
    println("small=${s1.toList() == mutableStateListOf(1, 2, 3).toList()}")
    println("smallDiff=${s1.toList() == mutableStateListOf(1, 2, 4).toList()}")
    println("smallShort=${s1.toList() == mutableStateListOf(1, 2).toList()}")
    val big1 = mutableStateListOf<Int>(); val big2 = mutableStateListOf<Int>()
    for (n in 0 until 1000) { big1.add(n); big2.add(n) }
    println("wide=${big1.toList() == big2.toList()}")
    big2[999] = -1
    println("wideTailDiff=${big1.toList() == big2.toList()}")
    big2[999] = 999
    big2[0] = -1
    println("wideHeadDiff=${big1.toList() == big2.toList()}")
    println("nulls=${mutableStateListOf<Int?>(1, null, 3).toList() == mutableStateListOf<Int?>(1, null, 3).toList()}")
    println("customEqualsSame=${mutableStateListOf(ModEq(5)).toList() == mutableStateListOf(ModEq(15)).toList()}")
    println("customEqualsDiff=${mutableStateListOf(ModEq(5)).toList() == mutableStateListOf(ModEq(6)).toList()}")
}
