/*
 * KLIO actuals for the common immutable-singleton-map helpers.
 */
package kotlin.collections

internal actual fun <K, V> Map<out K, V>.toSingletonMap(): Map<K, V> {
    val e = entries.iterator().next()
    return mapOf(e.key to e.value)
}

/**
 * On the JVM `getOrDefault` is a member of the `Map` builtin, which the
 * compiled common surface never declares — the interpreter served it purely
 * by name, so a call site carried no return type. Declared here so `V`
 * reaches the caller; a `null` VALUE for a present key is returned as-is,
 * exactly as the JDK implementation does.
 */
public fun <K, V> Map<K, V>.getOrDefault(key: K, defaultValue: V): V {
    val value = get(key)
    if (value != null) return value
    @Suppress("UNCHECKED_CAST")
    return if (containsKey(key)) value as V else defaultValue
}

internal actual inline fun <K, V> Map<K, V>.toSingletonMapOrSelf(): Map<K, V> = toSingletonMap()
