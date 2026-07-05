// klio actuals for the `internal expect` helpers declared in
// upstream commonMain `kotlin/collections/Collections.kt`. The
// upstream JVM/JS/native bodies are tiny — pure overflow checks /
// trivial conversions — so the klio actuals are inlined here.

package kotlin.collections

import kotlin.random.Random

internal actual fun checkIndexOverflow(index: Int): Int {
    if (index < 0) throw ArithmeticException("Index overflow has happened.")
    return index
}

internal actual fun checkCountOverflow(count: Int): Int {
    if (count < 0) throw ArithmeticException("Count overflow has happened.")
    return count
}

internal actual fun mapCapacity(expectedSize: Int): Int = expectedSize

internal actual inline fun <E> buildListInternal(builderAction: MutableList<E>.() -> Unit): List<E> {
    val list = ArrayList<E>()
    list.builderAction()
    return list
}

internal actual inline fun <E> buildListInternal(capacity: Int, builderAction: MutableList<E>.() -> Unit): List<E> {
    val list = ArrayList<E>(capacity)
    list.builderAction()
    return list
}

internal actual inline fun <E> buildSetInternal(builderAction: MutableSet<E>.() -> Unit): Set<E> {
    val set = LinkedHashSet<E>()
    set.builderAction()
    return set
}

internal actual inline fun <E> buildSetInternal(capacity: Int, builderAction: MutableSet<E>.() -> Unit): Set<E> {
    val set = LinkedHashSet<E>(capacity)
    set.builderAction()
    return set
}

internal actual inline fun <K, V> buildMapInternal(builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    val map = LinkedHashMap<K, V>()
    map.builderAction()
    return map
}

internal actual inline fun <K, V> buildMapInternal(capacity: Int, builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    val map = LinkedHashMap<K, V>(capacity)
    map.builderAction()
    return map
}

// The interpreter's arrays are exact-sized; collection-to-array
// termination is the identity, as on JS.
internal actual fun <T> terminateCollectionToArray(collectionSize: Int, array: Array<T>): Array<T> = array

// Platform hooks the baked AbstractCollection.toArray path calls bare;
// the common implementations serve directly.
internal actual fun collectionToArray(collection: Collection<*>): Array<Any?> = collectionToArrayCommonImpl(collection)
internal actual fun <T> collectionToArray(collection: Collection<*>, array: Array<T>): Array<T> = collectionToArrayCommonImpl(collection, array)

public actual inline fun <reified T> Array<out T>?.orEmpty(): Array<out T> = this ?: emptyArray<T>()

public actual fun <T> MutableList<T>.fill(value: T): Unit {
    for (index in 0..lastIndex) this[index] = value
}

public actual fun <T> MutableList<T>.shuffle(): Unit = shuffle(Random)
