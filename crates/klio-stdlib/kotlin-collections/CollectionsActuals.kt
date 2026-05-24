// klio actuals for the `internal expect` helpers declared in
// upstream commonMain `kotlin/collections/Collections.kt`. The
// upstream JVM/JS/native bodies are tiny — pure overflow checks /
// trivial conversions — so the klio actuals are inlined here.

package kotlin.collections

internal fun checkIndexOverflow(index: Int): Int {
    if (index < 0) throw ArithmeticException("Index overflow has happened.")
    return index
}

internal fun checkCountOverflow(count: Int): Int {
    if (count < 0) throw ArithmeticException("Count overflow has happened.")
    return count
}

internal actual fun mapCapacity(expectedSize: Int): Int = expectedSize

internal inline fun <E> buildListInternal(builderAction: MutableList<E>.() -> Unit): List<E> {
    val list = ArrayList<E>()
    list.builderAction()
    return list
}

internal inline fun <E> buildListInternal(capacity: Int, builderAction: MutableList<E>.() -> Unit): List<E> {
    val list = ArrayList<E>(capacity)
    list.builderAction()
    return list
}

internal inline fun <E> buildSetInternal(builderAction: MutableSet<E>.() -> Unit): Set<E> {
    val set = LinkedHashSet<E>()
    set.builderAction()
    return set
}

internal inline fun <E> buildSetInternal(capacity: Int, builderAction: MutableSet<E>.() -> Unit): Set<E> {
    val set = LinkedHashSet<E>(capacity)
    set.builderAction()
    return set
}

internal inline fun <K, V> buildMapInternal(builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    val map = LinkedHashMap<K, V>()
    map.builderAction()
    return map
}

internal inline fun <K, V> buildMapInternal(capacity: Int, builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    val map = LinkedHashMap<K, V>(capacity)
    map.builderAction()
    return map
}
