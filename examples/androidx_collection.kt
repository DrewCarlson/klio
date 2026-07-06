// androidx.collection — the memory-efficient primitive/scatter collections the
// compose runtime is built on. This exercises the pack's surface end-to-end:
// scatter map/set, the object + primitive value lists (with sort), a primitive
// key/value map, the ordered scatter set, SparseArrayCompat, and LruCache
// (including eviction). Deterministic output.

import androidx.collection.LruCache
import androidx.collection.MutableIntIntMap
import androidx.collection.MutableOrderedScatterSet
import androidx.collection.SparseArrayCompat
import androidx.collection.mutableIntListOf
import androidx.collection.mutableObjectListOf
import androidx.collection.mutableScatterMapOf
import androidx.collection.mutableScatterSetOf

fun main() {
    // Scatter map: an open-addressed Map<K, V>.
    val map = mutableScatterMapOf("a" to 1, "b" to 2)
    map["c"] = 3
    map["b"] = 20
    println("scatterMap: size=" + map.size + " b=" + map["b"] + " hasC=" + map.contains("c"))

    // Scatter set: an open-addressed Set<E>.
    val set = mutableScatterSetOf(1, 2, 3)
    set.add(4)
    set.remove(2)
    println("scatterSet: size=" + set.size + " has3=" + set.contains(3) + " has2=" + set.contains(2))

    // Object list: an ArrayList<E> without boxing overhead.
    val list = mutableObjectListOf("x", "y")
    list.add("z")
    println("objectList: size=" + list.size + " [1]=" + list[1] + " last=" + list[list.size - 1])

    // Primitive value list: stores Int inline; sort is in place.
    val ints = mutableIntListOf(5, 3, 8, 1, 4)
    ints.sort()
    var total = 0
    ints.forEach { total += it }
    println("intList: sorted=" + ints + " sum=" + total + " first=" + ints.first())
    ints.sortDescending()
    println("intList: desc=" + ints)

    // Primitive key/value map: Int -> Int with no boxing.
    val counts = MutableIntIntMap()
    counts[10] = 100
    counts[20] = 200
    counts[10] = counts[10] + 1
    println("intIntMap: size=" + counts.size + " g10=" + counts[10] + " g20=" + counts[20])

    // Ordered scatter set: iterates in insertion order.
    val ordered = MutableOrderedScatterSet<String>()
    ordered.add("first")
    ordered.add("second")
    ordered.add("third")
    val order = StringBuilder()
    ordered.forEach { order.append(it).append(" ") }
    println("orderedSet: size=" + ordered.size + " order=" + order.toString().trim())

    // SparseArrayCompat: a memory-lean Int -> T map.
    val sparse = SparseArrayCompat<String>()
    sparse.put(1, "one")
    sparse.put(5, "five")
    sparse.put(9, "nine")
    println("sparseArray: size=" + sparse.size() + " g5=" + sparse.get(5) + " gMissing=" + sparse.get(3))

    // LruCache: bounded, least-recently-used eviction.
    val lru = LruCache<String, Int>(2)
    lru.put("a", 1)
    lru.put("b", 2)
    lru.get("a")        // touch "a" so "b" becomes least-recently-used
    lru.put("c", 3)     // evicts "b"
    println("lru: size=" + lru.size() + " a=" + lru.get("a") + " bEvicted=" + (lru.get("b") == null) + " c=" + lru.get("c"))
}
