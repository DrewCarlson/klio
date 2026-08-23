// contains/indexOf on Compose snapshot-state lists across both vector
// representations: null elements, first-match order, absent values,
// user-defined equals still dispatching, subLists, and boxed
// Int-vs-Long inequality on an Any-typed list.
import androidx.compose.runtime.mutableStateListOf

class ModEq(val n: Int) {
    override fun equals(other: Any?) = other is ModEq && other.n % 10 == n % 10
    override fun hashCode() = n % 10
}

fun main() {
    val small = mutableStateListOf(1, 2, 3, 2)
    println(small.contains(2)); println(small.contains(9))
    println(small.indexOf(2)); println(small.indexOf(9)); println(small.lastIndexOf(2))
    val big = mutableStateListOf<Int?>()
    for (n in 0 until 1000) big.add(n)
    big.add(null); big.add(77)
    println(big.contains(999)); println(big.contains(5000)); println(big.contains(null))
    println(big.indexOf(null)); println(big.indexOf(77)); println(big.indexOf(1001))
    val objs = mutableStateListOf(ModEq(3), ModEq(7))
    println(objs.contains(ModEq(13))); println(objs.indexOf(ModEq(17))); println(objs.contains(ModEq(4)))
    val strs = mutableStateListOf("a", "b", "b")
    println(strs.indexOf("b")); println(strs.contains("c"))
    val sub = big.subList(10, 20)
    println(sub.contains(15)); println(sub.indexOf(15)); println(sub.contains(5))
    val anyList = mutableStateListOf<Any>(77, "x")
    println(anyList.contains(77L)); println(anyList.contains(77))
}
