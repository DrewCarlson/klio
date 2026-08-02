/*
 * klio-authored actuals for the `kotlin.concurrent.atomics` array types.
 *
 * Same execution contract as AtomicsActuals.kt: the composite per-element
 * read-modify-write methods execute as host bindings under the receiver's
 * exclusive borrow (src/stdlib/implementations/atomics.zig), the bodies here
 * being the semantic reference; `loadAt`/`storeAt` are a single element
 * access under the cell lock; the inline `updateAt` family splices into
 * callers and is written as compare-and-set loops, thread-correct as source.
 */

package kotlin.concurrent.atomics

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract
import kotlin.internal.InlineOnly

/**
 * An [IntArray] in which elements may be updated atomically.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicIntArray {
    private val array: IntArray

    /**
     * Creates a new [AtomicIntArray] of the given [size], with all elements
     * initialized to zero.
     */
    public actual constructor(size: Int) {
        array = IntArray(size)
    }

    /** Creates a new [AtomicIntArray] filled with elements of the given [array]. */
    public actual constructor(array: IntArray) {
        this.array = array.copyOf()
    }

    /** Returns the number of elements in the array. */
    public actual val size: Int get() = array.size

    /**
     * Atomically loads the value from the element of this [AtomicIntArray] at
     * the given [index].
     */
    public actual fun loadAt(index: Int): Int {
        checkBounds(index)
        return array[index]
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicIntArray] at the given [index].
     */
    public actual fun storeAt(index: Int, newValue: Int) {
        checkBounds(index)
        array[index] = newValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicIntArray] at the given [index] and returns the old value.
     */
    public actual fun exchangeAt(index: Int, newValue: Int): Int {
        checkBounds(index)
        val oldValue = array[index]
        array[index] = newValue
        return oldValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicIntArray] at the given [index] if the current value equals the
     * [expected value][expectedValue]; returns true on success, false when the
     * current value differed.
     */
    public actual fun compareAndSetAt(index: Int, expectedValue: Int, newValue: Int): Boolean {
        checkBounds(index)
        if (array[index] != expectedValue) return false
        array[index] = newValue
        return true
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicIntArray] at the given [index] if the current value equals the
     * [expected value][expectedValue]; returns the witnessed value either way.
     */
    public actual fun compareAndExchangeAt(index: Int, expectedValue: Int, newValue: Int): Int {
        checkBounds(index)
        val oldValue = array[index]
        if (oldValue == expectedValue) {
            array[index] = newValue
        }
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the element of this
     * [AtomicIntArray] at the given [index] and returns the old value.
     */
    public actual fun fetchAndAddAt(index: Int, delta: Int): Int {
        checkBounds(index)
        val oldValue = array[index]
        array[index] += delta
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the element of this
     * [AtomicIntArray] at the given [index] and returns the new value.
     */
    public actual fun addAndFetchAt(index: Int, delta: Int): Int {
        checkBounds(index)
        array[index] += delta
        return array[index]
    }

    /** Returns the string representation of the underlying array. */
    public actual override fun toString(): String = array.contentToString()

    private fun checkBounds(index: Int) {
        if (index < 0 || index >= array.size) throw IndexOutOfBoundsException("index $index")
    }
}

/**
 * A [LongArray] in which elements may be updated atomically.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicLongArray {
    private val array: LongArray

    /**
     * Creates a new [AtomicLongArray] of the given [size], with all elements
     * initialized to zero.
     */
    public actual constructor(size: Int) {
        array = LongArray(size)
    }

    /** Creates a new [AtomicLongArray] filled with elements of the given [array]. */
    public actual constructor(array: LongArray) {
        this.array = array.copyOf()
    }

    /** Returns the number of elements in the array. */
    public actual val size: Int get() = array.size

    /**
     * Atomically loads the value from the element of this [AtomicLongArray]
     * at the given [index].
     */
    public actual fun loadAt(index: Int): Long {
        checkBounds(index)
        return array[index]
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicLongArray] at the given [index].
     */
    public actual fun storeAt(index: Int, newValue: Long) {
        checkBounds(index)
        array[index] = newValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicLongArray] at the given [index] and returns the old value.
     */
    public actual fun exchangeAt(index: Int, newValue: Long): Long {
        checkBounds(index)
        val oldValue = array[index]
        array[index] = newValue
        return oldValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicLongArray] at the given [index] if the current value equals the
     * [expected value][expectedValue]; returns true on success, false when the
     * current value differed.
     */
    public actual fun compareAndSetAt(index: Int, expectedValue: Long, newValue: Long): Boolean {
        checkBounds(index)
        if (array[index] != expectedValue) return false
        array[index] = newValue
        return true
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicLongArray] at the given [index] if the current value equals the
     * [expected value][expectedValue]; returns the witnessed value either way.
     */
    public actual fun compareAndExchangeAt(index: Int, expectedValue: Long, newValue: Long): Long {
        checkBounds(index)
        val oldValue = array[index]
        if (oldValue == expectedValue) {
            array[index] = newValue
        }
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the element of this
     * [AtomicLongArray] at the given [index] and returns the old value.
     */
    public actual fun fetchAndAddAt(index: Int, delta: Long): Long {
        checkBounds(index)
        val oldValue = array[index]
        array[index] += delta
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the element of this
     * [AtomicLongArray] at the given [index] and returns the new value.
     */
    public actual fun addAndFetchAt(index: Int, delta: Long): Long {
        checkBounds(index)
        array[index] += delta
        return array[index]
    }

    /** Returns the string representation of the underlying array. */
    public actual override fun toString(): String = array.contentToString()

    private fun checkBounds(index: Int) {
        if (index < 0 || index >= array.size) throw IndexOutOfBoundsException("index $index")
    }
}

/**
 * An [Array] in which elements may be updated atomically, with elements
 * compared by reference.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicArray<T> {
    private val array: Array<T>

    /** Creates a new [AtomicArray] filled with elements of the given [array]. */
    public actual constructor(array: Array<T>) {
        this.array = array.copyOf()
    }

    /** Returns the number of elements in the array. */
    public actual val size: Int get() = array.size

    /**
     * Atomically loads the value from the element of this [AtomicArray] at
     * the given [index].
     */
    public actual fun loadAt(index: Int): T {
        checkBounds(index)
        return array[index]
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicArray] at the given [index].
     */
    public actual fun storeAt(index: Int, newValue: T) {
        checkBounds(index)
        array[index] = newValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicArray] at the given [index] and returns the old value.
     */
    public actual fun exchangeAt(index: Int, newValue: T): T {
        checkBounds(index)
        val oldValue = array[index]
        array[index] = newValue
        return oldValue
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicArray] at the given [index] if the current value referentially
     * equals the [expected value][expectedValue]; returns true on success,
     * false when the current value differed.
     */
    public actual fun compareAndSetAt(index: Int, expectedValue: T, newValue: T): Boolean {
        checkBounds(index)
        if (array[index] !== expectedValue) return false
        array[index] = newValue
        return true
    }

    /**
     * Atomically stores the [new value][newValue] into the element of this
     * [AtomicArray] at the given [index] if the current value referentially
     * equals the [expected value][expectedValue]; returns the witnessed value
     * either way.
     */
    public actual fun compareAndExchangeAt(index: Int, expectedValue: T, newValue: T): T {
        checkBounds(index)
        val oldValue = array[index]
        if (oldValue === expectedValue) {
            array[index] = newValue
        }
        return oldValue
    }

    /** Returns the string representation of the underlying array. */
    public actual override fun toString(): String = array.contentToString()

    private fun checkBounds(index: Int) {
        if (index < 0 || index >= array.size) throw IndexOutOfBoundsException("index $index")
    }
}

/**
 * Atomically updates the element of this [AtomicIntArray] at the given
 * [index] using [transform]. [transform] may be invoked more than once when
 * the element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicIntArray.updateAt(index: Int, transform: (Int) -> Int): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return
    }
}

/**
 * Atomically updates the element of this [AtomicIntArray] at the given
 * [index] using [transform], returning the new value. [transform] may be
 * invoked more than once when the element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicIntArray.updateAndFetchAt(index: Int, transform: (Int) -> Int): Int {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        val newValue = transform(old)
        if (compareAndSetAt(index, old, newValue)) return newValue
    }
}

/**
 * Atomically updates the element of this [AtomicIntArray] at the given
 * [index] using [transform], returning the value replaced by the updated one.
 * [transform] may be invoked more than once when the element is concurrently
 * updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicIntArray.fetchAndUpdateAt(index: Int, transform: (Int) -> Int): Int {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return old
    }
}

/**
 * Atomically updates the element of this [AtomicLongArray] at the given
 * [index] using [transform]. [transform] may be invoked more than once when
 * the element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLongArray.updateAt(index: Int, transform: (Long) -> Long): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return
    }
}

/**
 * Atomically updates the element of this [AtomicLongArray] at the given
 * [index] using [transform], returning the new value. [transform] may be
 * invoked more than once when the element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLongArray.updateAndFetchAt(index: Int, transform: (Long) -> Long): Long {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        val newValue = transform(old)
        if (compareAndSetAt(index, old, newValue)) return newValue
    }
}

/**
 * Atomically updates the element of this [AtomicLongArray] at the given
 * [index] using [transform], returning the value replaced by the updated one.
 * [transform] may be invoked more than once when the element is concurrently
 * updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLongArray.fetchAndUpdateAt(index: Int, transform: (Long) -> Long): Long {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return old
    }
}

/**
 * Atomically updates the element of this [AtomicArray] at the given [index]
 * using [transform]. [transform] may be invoked more than once when the
 * element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicArray<T>.updateAt(index: Int, transform: (T) -> T): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return
    }
}

/**
 * Atomically updates the element of this [AtomicArray] at the given [index]
 * using [transform], returning the new value. [transform] may be invoked more
 * than once when the element is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicArray<T>.updateAndFetchAt(index: Int, transform: (T) -> T): T {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        val newValue = transform(old)
        if (compareAndSetAt(index, old, newValue)) return newValue
    }
}

/**
 * Atomically updates the element of this [AtomicArray] at the given [index]
 * using [transform], returning the value replaced by the updated one.
 * [transform] may be invoked more than once when the element is concurrently
 * updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicArray<T>.fetchAndUpdateAt(index: Int, transform: (T) -> T): T {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = loadAt(index)
        if (compareAndSetAt(index, old, transform(old))) return old
    }
}
