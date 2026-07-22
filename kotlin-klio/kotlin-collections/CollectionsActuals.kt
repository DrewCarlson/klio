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

private fun <E> __klio_buildList(builderAction: MutableList<E>.() -> Unit): List<E> =
    error("intrinsic kotlin.collections.__klio_buildList not installed")

private fun <E> __klio_buildList(capacity: Int, builderAction: MutableList<E>.() -> Unit): List<E> =
    error("intrinsic kotlin.collections.__klio_buildList not installed")

private fun <E> __klio_buildSet(builderAction: MutableSet<E>.() -> Unit): Set<E> =
    error("intrinsic kotlin.collections.__klio_buildSet not installed")

private fun <E> __klio_buildSet(capacity: Int, builderAction: MutableSet<E>.() -> Unit): Set<E> =
    error("intrinsic kotlin.collections.__klio_buildSet not installed")

private fun <K, V> __klio_buildMap(builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> =
    error("intrinsic kotlin.collections.__klio_buildMap not installed")

private fun <K, V> __klio_buildMap(capacity: Int, builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> =
    error("intrinsic kotlin.collections.__klio_buildMap not installed")

internal actual inline fun <E> buildListInternal(builderAction: MutableList<E>.() -> Unit): List<E> {
    return __klio_buildList(builderAction)
}

internal actual inline fun <E> buildListInternal(capacity: Int, builderAction: MutableList<E>.() -> Unit): List<E> {
    return __klio_buildList(capacity, builderAction)
}

internal actual inline fun <E> buildSetInternal(builderAction: MutableSet<E>.() -> Unit): Set<E> {
    return __klio_buildSet(builderAction)
}

internal actual inline fun <E> buildSetInternal(capacity: Int, builderAction: MutableSet<E>.() -> Unit): Set<E> {
    return __klio_buildSet(capacity, builderAction)
}

internal actual inline fun <K, V> buildMapInternal(builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    return __klio_buildMap(builderAction)
}

internal actual inline fun <K, V> buildMapInternal(capacity: Int, builderAction: MutableMap<K, V>.() -> Unit): Map<K, V> {
    return __klio_buildMap(capacity, builderAction)
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

// In-place operations run through the receiver's own get/set, so they work
// for any MutableList implementation (SnapshotStateList included), not only
// the interpreter's native list.
public actual fun <T> MutableList<T>.reverse(): Unit {
    var left = 0
    var right = lastIndex
    while (left < right) {
        val tmp = this[left]
        this[left] = this[right]
        this[right] = tmp
        left++
        right--
    }
}

public actual fun <T : Comparable<T>> MutableList<T>.sort(): Unit {
    val sorted = this.sorted()
    for (index in 0..lastIndex) this[index] = sorted[index]
}

public actual fun <T> MutableList<T>.sortWith(comparator: Comparator<in T>): Unit {
    val sorted = this.sortedWith(comparator)
    for (index in 0..lastIndex) this[index] = sorted[index]
}
