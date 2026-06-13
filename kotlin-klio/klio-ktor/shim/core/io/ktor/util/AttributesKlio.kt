// klio `actual` for the ktor-util `Attributes(concurrent)` factory.
//
// Upstream's native actual (`AttributesNative`) backs the map with
// `io.ktor.util.collections.ConcurrentMap`. klio backs it with a plain
// `LinkedHashMap` whose every operation holds the instance's monitor
// (`kotlin.synchronized` on `this`): attributes are reachable from
// `Dispatchers.Default` workers through the client machinery, so
// `computeIfAbsent` must evaluate `block` at most once per absent key
// under contention. The `Attributes` interface itself is consumed
// verbatim from upstream `Attributes.kt`; this is only the platform
// factory + backing.

package io.ktor.util

// The default mirrors the `expect fun Attributes(concurrent: Boolean = false)`
// so a bare `Attributes()` (the common-code call shape) resolves with no
// arguments through klio's interface-factory dispatch.
public actual fun Attributes(concurrent: Boolean = false): Attributes = KlioAttributes()

private class KlioAttributes : Attributes {
    private val map = LinkedHashMap<AttributeKey<*>, Any>()

    @Suppress("UNCHECKED_CAST")
    override fun <T : Any> getOrNull(key: AttributeKey<T>): T? =
        kotlin.synchronized(this) { map[key] as T? }

    override fun contains(key: AttributeKey<*>): Boolean =
        kotlin.synchronized(this) { map.containsKey(key) }

    override fun <T : Any> put(key: AttributeKey<T>, value: T) {
        kotlin.synchronized(this) { map[key] = value }
    }

    override fun <T : Any> remove(key: AttributeKey<T>) {
        kotlin.synchronized(this) { map.remove(key) }
    }

    @Suppress("UNCHECKED_CAST")
    override fun <T : Any> computeIfAbsent(key: AttributeKey<T>, block: () -> T): T =
        kotlin.synchronized(this) {
            val existing = map[key]
            if (existing != null) {
                existing as T
            } else {
                val value = block()
                map[key] = value
                value
            }
        }

    override val allKeys: List<AttributeKey<*>>
        get() = kotlin.synchronized(this) { map.keys.toList() }
}
