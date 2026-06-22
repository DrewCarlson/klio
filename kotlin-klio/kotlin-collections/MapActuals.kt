/*
 * KLIO actuals for the common immutable-singleton-map helpers.
 */
package kotlin.collections

internal actual fun <K, V> Map<out K, V>.toSingletonMap(): Map<K, V> {
    val e = entries.iterator().next()
    return mapOf(e.key to e.value)
}

internal actual inline fun <K, V> Map<K, V>.toSingletonMapOrSelf(): Map<K, V> = toSingletonMap()
