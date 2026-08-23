// Bulk mutation on SnapshotStateList: addAll and removeRange, the two
// operations that route through the persistent-vector builder's bulk
// paths. Exercises tail-only fills, root-trie growth across levels,
// partial and full range removal, and the state left for further ops.
import androidx.compose.runtime.mutableStateListOf

fun main() {
    val l = mutableStateListOf<Int>()
    println(l.addAll(listOf(1, 2, 3)))
    println(l.addAll(emptyList()))
    println(l.toList())

    // Grow across the 32-element tail boundary and into the root trie.
    val big = mutableStateListOf<Int>()
    big.addAll((0 until 100).toList())
    println(big.size)
    println(big[0]); println(big[31]); println(big[32]); println(big[99])

    // Partial removal in the middle, then from the front.
    big.removeRange(33, 66)
    println(big.size)
    println(big[32]); println(big[33])
    big.removeRange(0, 10)
    println(big.size)
    println(big[0])

    // Removal to empty, then reuse of the list.
    big.removeRange(0, big.size)
    println(big.size)
    big.addAll(listOf(7, 8))
    println(big.toList())

    // Deep list: two root levels, bulk removal keeps order.
    val deep = mutableStateListOf<Int>()
    deep.addAll((0 until 2000).toList())
    deep.removeRange(100, 1500)
    println(deep.size)
    println(deep[99]); println(deep[100]); println(deep[599])

    // subList clear routes through the same removeRange.
    val sub = mutableStateListOf<Int>()
    sub.addAll((0 until 50).toList())
    sub.subList(10, 40).clear()
    println(sub.size)
    println(sub[9]); println(sub[10])

    var sum = 0
    for (v in deep) sum += v
    println(sum)
}
