package kotlinx.serialization.json.internal

internal actual fun <K, V> createMapForCache(initialCapacity: Int): MutableMap<K, V> = HashMap(initialCapacity)
