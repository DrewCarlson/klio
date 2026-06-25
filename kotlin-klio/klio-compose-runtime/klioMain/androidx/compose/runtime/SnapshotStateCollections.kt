// Observable collections — mutating one triggers recomposition of any composable
// that read it. Each collection is a state object: reads route through
// StateObservation.notifyRead (subscribing the running composable's group),
// mutations through notifyWrite (invalidating those groups). The list rides
// AbstractMutableList, whose derived operations (iterator, contains, addAll,
// clear, …) route through the five read/write-hooked primitives below; the map
// and set delegate to a plain backing collection per operation.

package androidx.compose.runtime

public class SnapshotStateList<T> : AbstractMutableList<T>() {
    private val backing = ArrayList<T>()
    private fun read() = StateObservation.notifyRead(this)
    private fun write() = StateObservation.notifyWrite(this)

    override val size: Int get() { read(); return backing.size }
    override fun get(index: Int): T { read(); return backing[index] }
    override fun set(index: Int, element: T): T { val r = backing.set(index, element); write(); return r }
    override fun add(index: Int, element: T) { backing.add(index, element); write() }
    override fun removeAt(index: Int): T { val r = backing.removeAt(index); write(); return r }
}

public class SnapshotStateMap<K, V> : MutableMap<K, V> {
    private val backing = LinkedHashMap<K, V>()
    private fun read() = StateObservation.notifyRead(this)
    private fun write() = StateObservation.notifyWrite(this)

    override val size: Int get() { read(); return backing.size }
    override fun isEmpty(): Boolean { read(); return backing.isEmpty() }
    override fun containsKey(key: K): Boolean { read(); return backing.containsKey(key) }
    override fun containsValue(value: V): Boolean { read(); return backing.containsValue(value) }
    override fun get(key: K): V? { read(); return backing[key] }
    override val keys: MutableSet<K> get() { read(); return backing.keys }
    override val values: MutableCollection<V> get() { read(); return backing.values }
    override val entries: MutableSet<MutableMap.MutableEntry<K, V>> get() { read(); return backing.entries }

    override fun put(key: K, value: V): V? { val r = backing.put(key, value); write(); return r }
    override fun remove(key: K): V? { val had = backing.containsKey(key); val r = backing.remove(key); if (had) write(); return r }
    override fun putAll(from: Map<out K, V>) { if (from.isNotEmpty()) { backing.putAll(from); write() } }
    override fun clear() { if (backing.isNotEmpty()) { backing.clear(); write() } }

    override fun toString(): String { read(); return backing.toString() }
}

public class SnapshotStateSet<T> : MutableSet<T> {
    private val backing = LinkedHashSet<T>()
    private fun read() = StateObservation.notifyRead(this)
    private fun write() = StateObservation.notifyWrite(this)

    override val size: Int get() { read(); return backing.size }
    override fun isEmpty(): Boolean { read(); return backing.isEmpty() }
    override fun contains(element: T): Boolean { read(); return backing.contains(element) }
    override fun containsAll(elements: Collection<T>): Boolean { read(); return backing.containsAll(elements) }
    override fun iterator(): MutableIterator<T> { read(); return backing.iterator() }

    override fun add(element: T): Boolean { val r = backing.add(element); if (r) write(); return r }
    override fun addAll(elements: Collection<T>): Boolean { val r = backing.addAll(elements); if (r) write(); return r }
    override fun clear() { if (backing.isNotEmpty()) { backing.clear(); write() } }
    override fun remove(element: T): Boolean { val r = backing.remove(element); if (r) write(); return r }
    override fun removeAll(elements: Collection<T>): Boolean { val r = backing.removeAll(elements); if (r) write(); return r }
    override fun retainAll(elements: Collection<T>): Boolean { val r = backing.retainAll(elements); if (r) write(); return r }

    override fun toString(): String { read(); return backing.toString() }
}

// ----- factories -----

public fun <T> mutableStateListOf(): SnapshotStateList<T> = SnapshotStateList()

public fun <T> mutableStateListOf(vararg elements: T): SnapshotStateList<T> {
    val list = SnapshotStateList<T>()
    for (e in elements) list.add(e)
    return list
}

public fun <T> Iterable<T>.toMutableStateList(): SnapshotStateList<T> {
    val list = SnapshotStateList<T>()
    for (e in this) list.add(e)
    return list
}

public fun <K, V> mutableStateMapOf(): SnapshotStateMap<K, V> = SnapshotStateMap()

public fun <K, V> mutableStateMapOf(vararg pairs: Pair<K, V>): SnapshotStateMap<K, V> {
    val map = SnapshotStateMap<K, V>()
    for (p in pairs) map.put(p.first, p.second)
    return map
}

public fun <T> mutableStateSetOf(): SnapshotStateSet<T> = SnapshotStateSet()

public fun <T> mutableStateSetOf(vararg elements: T): SnapshotStateSet<T> {
    val set = SnapshotStateSet<T>()
    for (e in elements) set.add(e)
    return set
}
