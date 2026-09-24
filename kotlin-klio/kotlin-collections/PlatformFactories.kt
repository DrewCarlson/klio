/*
 * klio-authored declarations for the platform collection factories and
 * conversions the interpreter serves natively.
 *
 * These exist so the symbol table has NO HOLES: a callable the runtime can
 * dispatch must also be a declaration the resolver can see, or a bare call to
 * it has to fall back to a name probe. The bodies are the platform semantics —
 * a sorted set/map ordered by natural order or an explicit comparator, and a
 * string-keyed linked map — expressed against klio's own collections rather
 * than a JVM `TreeSet`/`SortedMap`, which klio does not have.
 */
package kotlin.collections

public fun <T : Comparable<T>> sortedSetOf(vararg elements: T): MutableSet<T> {
    val out = LinkedHashSet<T>()
    for (e in elements.sorted()) out.add(e)
    return out
}

public fun <T> sortedSetOf(comparator: Comparator<in T>, vararg elements: T): MutableSet<T> {
    val out = LinkedHashSet<T>()
    for (e in elements.sortedWith(comparator)) out.add(e)
    return out
}

public fun <K : Comparable<K>, V> sortedMapOf(vararg pairs: Pair<K, V>): MutableMap<K, V> {
    val out = LinkedHashMap<K, V>()
    for (p in pairs.sortedBy { it.first }) out[p.first] = p.second
    return out
}

public fun <K, V> sortedMapOf(comparator: Comparator<in K>, vararg pairs: Pair<K, V>): MutableMap<K, V> {
    val out = LinkedHashMap<K, V>()
    for (p in pairs.sortedWith(compareBy(comparator) { it.first })) out[p.first] = p.second
    return out
}

/** This map's entries ordered by the natural order of their keys. */
public fun <K : Comparable<K>, V> Map<out K, V>.toSortedMap(): MutableMap<K, V> =
    toSortedMap(naturalOrder<K>())

/**
 * This map's entries ordered by [comparator] over their keys. Keys the
 * comparator finds equal are one entry, as in a sorted map: the first key
 * with the last value.
 */
@Suppress("UNCHECKED_CAST")
public fun <K, V> Map<out K, V>.toSortedMap(comparator: Comparator<in K>): MutableMap<K, V> {
    val out = LinkedHashMap<K, V>()
    var first = true
    var last: K? = null
    for (e in entries.sortedWith(compareBy(comparator) { it.key })) {
        if (!first && comparator.compare(last as K, e.key) == 0) {
            out[last as K] = e.value
            continue
        }
        out[e.key] = e.value
        last = e.key
        first = false
    }
    return out
}

public fun <V> linkedStringMapOf(vararg pairs: Pair<String, V>): LinkedHashMap<String, V> {
    val out = LinkedHashMap<String, V>()
    for (p in pairs) out[p.first] = p.second
    return out
}
