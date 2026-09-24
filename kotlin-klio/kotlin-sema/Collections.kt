// klio `actual`s the sema pipeline uses for the internal array helpers of
// CollectionsH.kt, as Kotlin/Native declares them.

package kotlin.collections

@Suppress("UNCHECKED_CAST")
internal actual fun <T> arrayOfNulls(reference: Array<T>, size: Int): Array<T> = arrayOfNulls<Any>(size) as Array<T>

internal actual fun <T> Array<out T>.copyToArrayOfAny(isVarargs: Boolean): Array<out Any?> =
    if (isVarargs) this else this.copyOf()

/** The count of elements in each group, as Kotlin/Native declares it. */
public actual fun <T, K> Grouping<T, K>.eachCount(): Map<K, Int> = eachCountTo(mutableMapOf<K, Int>())

/**
 * An insertion-ordered [HashSet], as the JVM and JS declare it. Its values
 * are the host's sets, which keep insertion order.
 */
public actual open class LinkedHashSet<E> : HashSet<E>, MutableSet<E> {
    public actual constructor() : super()
    public actual constructor(initialCapacity: Int) : super(initialCapacity)
    public actual constructor(initialCapacity: Int, loadFactor: Float) : super(initialCapacity, loadFactor)
    public actual constructor(elements: Collection<E>) : super(elements)
}

/**
 * An insertion-ordered [HashMap], as the JVM and JS declare it. Its values
 * are the host's maps, which keep insertion order.
 */
public actual open class LinkedHashMap<K, V> : HashMap<K, V>, MutableMap<K, V> {
    public actual constructor() : super()
    public actual constructor(initialCapacity: Int) : super(initialCapacity)
    public actual constructor(initialCapacity: Int, loadFactor: Float) : super(initialCapacity, loadFactor)
    public actual constructor(original: Map<out K, V>) : super(original)
}
