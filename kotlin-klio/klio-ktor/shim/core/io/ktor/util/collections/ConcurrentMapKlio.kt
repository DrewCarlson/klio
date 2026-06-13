// klio `actual` for `io.ktor.util.collections.ConcurrentMap`. klio runs
// real worker threads, so this mirrors upstream's native actual: a
// `LinkedHashMap` delegate where every operation holds the map's own
// monitor (`kotlin.synchronized` on `this`, the host's per-object
// reentrant lock). `computeIfAbsent` evaluates `block` at most once per
// absent key because the whole probe-compute-insert runs under the
// monitor, and the view properties return copies taken under the
// monitor, exactly like upstream's native `ConcurrentMap`.

package io.ktor.util.collections

public actual class ConcurrentMap<Key, Value> actual constructor(
    initialCapacity: Int,
) : MutableMap<Key, Value> {
    private val delegate: MutableMap<Key, Value> = LinkedHashMap(initialCapacity)

    public actual fun computeIfAbsent(key: Key, block: () -> Value): Value = kotlin.synchronized(this) {
        if (delegate.containsKey(key)) {
            delegate[key]!!
        } else {
            val value = block()
            delegate[key] = value
            value
        }
    }

    public actual fun remove(key: Key, value: Value): Boolean = kotlin.synchronized(this) {
        if (delegate[key] == value) {
            delegate.remove(key)
            true
        } else {
            false
        }
    }

    actual override fun remove(key: Key): Value? = kotlin.synchronized(this) { delegate.remove(key) }
    actual override fun clear() {
        kotlin.synchronized(this) { delegate.clear() }
    }
    actual override fun put(key: Key, value: Value): Value? = kotlin.synchronized(this) { delegate.put(key, value) }
    actual override fun putAll(from: Map<out Key, Value>) {
        kotlin.synchronized(this) { delegate.putAll(from) }
    }
    actual override val entries: MutableSet<MutableMap.MutableEntry<Key, Value>>
        get() = kotlin.synchronized(this) { delegate.toMutableMap().entries }
    actual override val keys: MutableSet<Key>
        get() = kotlin.synchronized(this) { delegate.keys.toMutableSet() }
    actual override val values: MutableCollection<Value>
        get() = kotlin.synchronized(this) { delegate.values.toMutableList() }
    actual override fun containsKey(key: Key): Boolean = kotlin.synchronized(this) { delegate.containsKey(key) }
    actual override fun containsValue(value: Value): Boolean = kotlin.synchronized(this) { delegate.containsValue(value) }
    actual override fun get(key: Key): Value? = kotlin.synchronized(this) { delegate[key] }
    actual override fun isEmpty(): Boolean = kotlin.synchronized(this) { delegate.isEmpty() }
    actual override val size: Int get() = kotlin.synchronized(this) { delegate.size }
}
