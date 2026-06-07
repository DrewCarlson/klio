// klio `actual` for `io.ktor.util.collections.ConcurrentMap`. klio runs
// single-threaded, so a plain `LinkedHashMap` provides the (uncontended)
// concurrent-map semantics; `computeIfAbsent` / `remove(key, value)` mirror
// the expect's contract.

package io.ktor.util.collections

public actual class ConcurrentMap<Key, Value> actual constructor(
    initialCapacity: Int,
) : MutableMap<Key, Value> {
    private val delegate: MutableMap<Key, Value> = LinkedHashMap(initialCapacity)

    public actual fun computeIfAbsent(key: Key, block: () -> Value): Value {
        delegate[key]?.let { return it }
        val value = block()
        delegate[key] = value
        return value
    }

    public actual fun remove(key: Key, value: Value): Boolean {
        if (delegate[key] == value) {
            delegate.remove(key)
            return true
        }
        return false
    }

    actual override fun remove(key: Key): Value? = delegate.remove(key)
    actual override fun clear() {
        delegate.clear()
    }
    actual override fun put(key: Key, value: Value): Value? = delegate.put(key, value)
    actual override fun putAll(from: Map<out Key, Value>) {
        delegate.putAll(from)
    }
    actual override val entries: MutableSet<MutableMap.MutableEntry<Key, Value>>
        get() = delegate.entries
    actual override val keys: MutableSet<Key> get() = delegate.keys
    actual override val values: MutableCollection<Value> get() = delegate.values
    actual override fun containsKey(key: Key): Boolean = delegate.containsKey(key)
    actual override fun containsValue(value: Value): Boolean = delegate.containsValue(value)
    actual override fun get(key: Key): Value? = delegate[key]
    actual override fun isEmpty(): Boolean = delegate.isEmpty()
    actual override val size: Int get() = delegate.size
}
