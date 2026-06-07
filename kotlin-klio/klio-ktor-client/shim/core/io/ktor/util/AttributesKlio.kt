// klio `actual` for the ktor-util `Attributes(concurrent)` factory.
//
// Upstream's native actual (`AttributesNative`) backs the map with
// `io.ktor.util.collections.ConcurrentMap`; klio's interpreter is
// single-threaded per Vm and a plain `LinkedHashMap` keyed by the data-class
// `AttributeKey` gives the same observable behaviour without pulling the
// concurrency type. The `Attributes` interface itself is consumed verbatim
// from upstream `Attributes.kt`; this is only the platform factory + backing.

package io.ktor.util

// The default mirrors the `expect fun Attributes(concurrent: Boolean = false)`
// so a bare `Attributes()` (the common-code call shape) resolves with no
// arguments through klio's interface-factory dispatch.
public actual fun Attributes(concurrent: Boolean = false): Attributes = KlioAttributes()

private class KlioAttributes : Attributes {
    private val map = LinkedHashMap<AttributeKey<*>, Any>()

    @Suppress("UNCHECKED_CAST")
    override fun <T : Any> getOrNull(key: AttributeKey<T>): T? = map[key] as T?

    override fun contains(key: AttributeKey<*>): Boolean = map.containsKey(key)

    override fun <T : Any> put(key: AttributeKey<T>, value: T) {
        map[key] = value
    }

    override fun <T : Any> remove(key: AttributeKey<T>) {
        map.remove(key)
    }

    @Suppress("UNCHECKED_CAST")
    override fun <T : Any> computeIfAbsent(key: AttributeKey<T>, block: () -> T): T {
        map[key]?.let { return it as T }
        val value = block()
        map[key] = value
        return value
    }

    override val allKeys: List<AttributeKey<*>>
        get() = map.keys.toList()
}
