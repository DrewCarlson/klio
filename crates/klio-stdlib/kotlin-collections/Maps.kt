// Upstream's `kotlin/collections/Maps.kt` declares the `EmptyMap`
// singleton with a `Serializable` supertype that klio's parser
// doesn't carry through. Until the missing interface is available
// (or selective-include is added to the curated SOURCES bundle),
// klio ships the high-frequency Map<K, V> entry-typed extensions
// here. Bodies match upstream.

package kotlin.collections

public inline fun <K, V> Map<out K, V>.forEach(action: (Map.Entry<K, V>) -> Unit): Unit {
    for (element in this) action(element)
}

public inline fun <K, V> Map<out K, V>.filter(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Map<K, V> {
    val result = LinkedHashMap<K, V>()
    for (entry in this) if (predicate(entry)) result[entry.key] = entry.value
    return result
}

public inline fun <K, V> Map<out K, V>.filterNot(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Map<K, V> {
    val result = LinkedHashMap<K, V>()
    for (entry in this) if (!predicate(entry)) result[entry.key] = entry.value
    return result
}

public inline fun <K, V> Map<out K, V>.filterKeys(predicate: (K) -> Boolean): Map<K, V> {
    val result = LinkedHashMap<K, V>()
    for (entry in this) if (predicate(entry.key)) result[entry.key] = entry.value
    return result
}

public inline fun <K, V> Map<out K, V>.filterValues(predicate: (V) -> Boolean): Map<K, V> {
    val result = LinkedHashMap<K, V>()
    for (entry in this) if (predicate(entry.value)) result[entry.key] = entry.value
    return result
}

public inline fun <K, V, R> Map<out K, V>.map(
    transform: (Map.Entry<K, V>) -> R,
): List<R> {
    val result = ArrayList<R>()
    for (entry in this) result.add(transform(entry))
    return result
}

public inline fun <K, V, R> Map<out K, V>.mapValues(
    transform: (Map.Entry<K, V>) -> R,
): Map<K, R> {
    val result = LinkedHashMap<K, R>()
    for (entry in this) result[entry.key] = transform(entry)
    return result
}

public inline fun <K, V, R> Map<out K, V>.mapKeys(
    transform: (Map.Entry<K, V>) -> R,
): Map<R, V> {
    val result = LinkedHashMap<R, V>()
    for (entry in this) result[transform(entry)] = entry.value
    return result
}

public inline fun <K, V> Map<out K, V>.any(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Boolean {
    for (entry in this) if (predicate(entry)) return true
    return false
}

public inline fun <K, V> Map<out K, V>.all(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Boolean {
    for (entry in this) if (!predicate(entry)) return false
    return true
}

public inline fun <K, V> Map<out K, V>.none(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Boolean {
    for (entry in this) if (predicate(entry)) return false
    return true
}

public inline fun <K, V> Map<out K, V>.count(
    predicate: (Map.Entry<K, V>) -> Boolean,
): Int {
    var n = 0
    for (entry in this) if (predicate(entry)) n++
    return n
}
