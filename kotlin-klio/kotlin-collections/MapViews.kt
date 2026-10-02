/*
 * A map's `keys`, `values` and `entries`, as Kotlin/Native's `HashMap` declares them:
 * views that read the map through its own lookups and walk its entries in place, holding
 * no elements of their own. A map makes each once and keeps it.
 */
package kotlin.collections

/** A map's `keys`: the set of its keys as the map holds them now. */
internal class HashMapKeys<E> internal constructor(
    private val backing: MutableMap<E, *>
) : AbstractMutableSet<E>() {
    override val size: Int get() = backing.size
    override fun isEmpty(): Boolean = backing.isEmpty()
    override fun contains(element: E): Boolean = backing.containsKey(element)
    override fun clear() = backing.clear()
    override fun add(element: E): Boolean = throw UnsupportedOperationException()
    override fun addAll(elements: Collection<E>): Boolean = throw UnsupportedOperationException()
    override fun remove(element: E): Boolean = __klio_mapRemoveKey(backing, element)
    override fun iterator(): MutableIterator<E> = __klio_mapIterator(backing, KEYS)

    override fun removeAll(elements: Collection<E>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.removeAll(elements)
    }

    override fun retainAll(elements: Collection<E>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.retainAll(elements)
    }
}

/** A map's `values`: a collection of its values as the map holds them now. */
internal class HashMapValues<V> internal constructor(
    private val backing: MutableMap<*, V>
) : AbstractMutableCollection<V>() {
    override val size: Int get() = backing.size
    override fun isEmpty(): Boolean = backing.isEmpty()
    override fun contains(element: V): Boolean = backing.containsValue(element)
    override fun add(element: V): Boolean = throw UnsupportedOperationException()
    override fun addAll(elements: Collection<V>): Boolean = throw UnsupportedOperationException()
    override fun clear() = backing.clear()
    override fun iterator(): MutableIterator<V> = __klio_mapIterator(backing, VALUES)

    override fun remove(element: V): Boolean {
        __klio_mapCheckMutable(backing)
        return super.remove(element)
    }

    override fun removeAll(elements: Collection<V>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.removeAll(elements)
    }

    override fun retainAll(elements: Collection<V>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.retainAll(elements)
    }
}

/**
 * A map's `entries`: the set of its entries, each the map's own node, so `setValue` writes
 * the map and an entry read while its key is in the map reads the map's value.
 */
internal class HashMapEntrySet<K, V> internal constructor(
    backing: MutableMap<K, V>
) : HashMapEntrySetBase<K, V, MutableMap.MutableEntry<K, V>>(backing) {
    override fun iterator(): MutableIterator<MutableMap.MutableEntry<K, V>> = __klio_mapIterator(backing, ENTRIES)
}

/**
 * The entry set's members over any `Map.Entry`, as Kotlin/Native declares them: `contains`
 * and `remove` take an entry of any kind, matched by its key and value.
 */
internal abstract class HashMapEntrySetBase<K, V, E : Map.Entry<K, V>> internal constructor(
    protected val backing: MutableMap<K, V>
) : AbstractMutableSet<E>() {
    override val size: Int get() = backing.size
    override fun isEmpty(): Boolean = backing.isEmpty()
    override fun contains(element: E): Boolean = containsEntry(element)
    override fun clear() = backing.clear()
    override fun add(element: E): Boolean = throw UnsupportedOperationException()
    override fun addAll(elements: Collection<E>): Boolean = throw UnsupportedOperationException()

    override fun remove(element: E): Boolean {
        __klio_mapCheckMutable(backing)
        if (!containsEntry(element)) return false
        backing.remove(element.key)
        return true
    }

    override fun removeAll(elements: Collection<E>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.removeAll(elements)
    }

    override fun retainAll(elements: Collection<E>): Boolean {
        __klio_mapCheckMutable(backing)
        return super.retainAll(elements)
    }

    /** Whether the map holds `element`'s key with `element`'s value. */
    private fun containsEntry(element: Any?): Boolean {
        if (element !is Map.Entry<*, *>) return false
        @Suppress("UNCHECKED_CAST")
        val map = backing as Map<Any?, Any?>
        val value = map[element.key]
        return value == element.value && (value != null || map.containsKey(element.key))
    }
}

private const val KEYS = 0
private const val VALUES = 1
private const val ENTRIES = 2

/** An iterator over `map`'s keys, values or entries (`kind`) that walks the map itself. */
private fun <T> __klio_mapIterator(map: Map<*, *>, kind: Int): MutableIterator<T> =
    error("intrinsic kotlin.collections.__klio_mapIterator not installed")

/** Removes `key` from `map`, answering whether the map held it, whatever its value. */
private fun <K> __klio_mapRemoveKey(map: MutableMap<K, *>, key: K): Boolean =
    error("intrinsic kotlin.collections.__klio_mapRemoveKey not installed")

/** Throws `UnsupportedOperationException` for a map that may not change. */
private fun __klio_mapCheckMutable(map: Map<*, *>): Unit =
    error("intrinsic kotlin.collections.__klio_mapCheckMutable not installed")
