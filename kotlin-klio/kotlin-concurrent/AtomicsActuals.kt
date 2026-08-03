/*
 * klio-authored actuals for `kotlin.concurrent.atomics`.
 *
 * KLIO runs real worker threads. The composite read-modify-write methods
 * (`exchange`, `compareAndSet`, `compareAndExchange`, `fetchAndAdd`,
 * `addAndFetch`) execute as host bindings under the receiver cell's exclusive
 * borrow (see src/stdlib/implementations/atomics.zig); the bodies written here
 * are the semantic reference the bindings implement. `load` and `store` are a
 * single field access, already atomic under the cell lock. The inline
 * `update`/`fetchAndUpdate`/`updateAndFetch` extensions splice into callers,
 * so they cannot be host-shadowed — they are written as compare-and-set loops
 * and are thread-correct as source.
 */

package kotlin.concurrent.atomics

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract
import kotlin.internal.InlineOnly

/**
 * An [Int] value that may be updated atomically.
 *
 * @constructor Creates a new [AtomicInt] initialized with the specified value.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicInt public actual constructor(private var value: Int) {

    /** Atomically loads the value from this [AtomicInt]. */
    public actual fun load(): Int = value

    /** Atomically stores the [new value][newValue] into this [AtomicInt]. */
    public actual fun store(newValue: Int) { value = newValue }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicInt]
     * and returns the old value.
     */
    public actual fun exchange(newValue: Int): Int {
        val oldValue = value
        value = newValue
        return oldValue
    }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicInt]
     * if the current value equals the [expected value][expectedValue]; returns
     * true on success, false when the current value differed.
     */
    public actual fun compareAndSet(expectedValue: Int, newValue: Int): Boolean {
        if (value != expectedValue) return false
        value = newValue
        return true
    }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicInt]
     * if the current value equals the [expected value][expectedValue]; returns
     * the witnessed value either way.
     */
    public actual fun compareAndExchange(expectedValue: Int, newValue: Int): Int {
        val oldValue = value
        if (oldValue == expectedValue) {
            value = newValue
        }
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the current value and
     * returns the old value.
     */
    public actual fun fetchAndAdd(delta: Int): Int {
        val oldValue = value
        value += delta
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the current value and
     * returns the new value.
     */
    public actual fun addAndFetch(delta: Int): Int {
        value += delta
        return value
    }

    /** Returns the string representation of the underlying [Int] value. */
    public actual override fun toString(): String = value.toString()
}

/**
 * A [Long] value that may be updated atomically.
 *
 * @constructor Creates a new [AtomicLong] initialized with the specified value.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicLong public actual constructor(private var value: Long) {

    /** Atomically loads the value from this [AtomicLong]. */
    public actual fun load(): Long = value

    /** Atomically stores the [new value][newValue] into this [AtomicLong]. */
    public actual fun store(newValue: Long) { value = newValue }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicLong]
     * and returns the old value.
     */
    public actual fun exchange(newValue: Long): Long {
        val oldValue = value
        value = newValue
        return oldValue
    }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicLong]
     * if the current value equals the [expected value][expectedValue]; returns
     * true on success, false when the current value differed.
     */
    public actual fun compareAndSet(expectedValue: Long, newValue: Long): Boolean {
        if (value != expectedValue) return false
        value = newValue
        return true
    }

    /**
     * Atomically stores the given [new value][newValue] into this [AtomicLong]
     * if the current value equals the [expected value][expectedValue]; returns
     * the witnessed value either way.
     */
    public actual fun compareAndExchange(expectedValue: Long, newValue: Long): Long {
        val oldValue = value
        if (oldValue == expectedValue) {
            value = newValue
        }
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the current value and
     * returns the old value.
     */
    public actual fun fetchAndAdd(delta: Long): Long {
        val oldValue = value
        value += delta
        return oldValue
    }

    /**
     * Atomically adds the [given value][delta] to the current value and
     * returns the new value.
     */
    public actual fun addAndFetch(delta: Long): Long {
        value += delta
        return value
    }

    /** Returns the string representation of the underlying [Long] value. */
    public actual override fun toString(): String = value.toString()
}

/**
 * A [Boolean] value that may be updated atomically.
 *
 * @constructor Creates a new [AtomicBoolean] initialized with the specified value.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicBoolean public actual constructor(private var value: Boolean) {

    /** Atomically loads the value from this [AtomicBoolean]. */
    public actual fun load(): Boolean = value

    /** Atomically stores the [new value][newValue] into this [AtomicBoolean]. */
    public actual fun store(newValue: Boolean) { value = newValue }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicBoolean] and returns the old value.
     */
    public actual fun exchange(newValue: Boolean): Boolean {
        val oldValue = value
        value = newValue
        return oldValue
    }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicBoolean] if the current value equals the
     * [expected value][expectedValue]; returns true on success, false when the
     * current value differed.
     */
    public actual fun compareAndSet(expectedValue: Boolean, newValue: Boolean): Boolean {
        if (value != expectedValue) return false
        value = newValue
        return true
    }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicBoolean] if the current value equals the
     * [expected value][expectedValue]; returns the witnessed value either way.
     */
    public actual fun compareAndExchange(expectedValue: Boolean, newValue: Boolean): Boolean {
        val oldValue = value
        if (oldValue == expectedValue) {
            value = newValue
        }
        return oldValue
    }

    /** Returns the string representation of the underlying [Boolean] value. */
    public actual override fun toString(): String = value.toString()
}

/**
 * An object reference that may be updated atomically.
 *
 * @constructor Creates a new [AtomicReference] initialized with the specified value.
 */
@SinceKotlin("2.1")
@ExperimentalAtomicApi
public actual class AtomicReference<T> public actual constructor(private var value: T) {

    /** Atomically loads the value from this [AtomicReference]. */
    public actual fun load(): T = value

    /** Atomically stores the [new value][newValue] into this [AtomicReference]. */
    public actual fun store(newValue: T) { value = newValue }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicReference] and returns the old value.
     */
    public actual fun exchange(newValue: T): T {
        val oldValue = value
        value = newValue
        return oldValue
    }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicReference] if the current value referentially equals the
     * [expected value][expectedValue]; returns true on success, false when the
     * current value differed.
     */
    public actual fun compareAndSet(expectedValue: T, newValue: T): Boolean {
        if (value !== expectedValue) return false
        value = newValue
        return true
    }

    /**
     * Atomically stores the given [new value][newValue] into this
     * [AtomicReference] if the current value referentially equals the
     * [expected value][expectedValue]; returns the witnessed value either way.
     */
    public actual fun compareAndExchange(expectedValue: T, newValue: T): T {
        val oldValue = value
        if (oldValue === expectedValue) {
            value = newValue
        }
        return oldValue
    }

    /** Returns the string representation of the underlying value. */
    public actual override fun toString(): String = value.toString()
}

/**
 * Atomically updates the value of this [AtomicInt] with the value obtained by
 * calling [transform] on the current value. [transform] may be invoked more
 * than once when the value is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicInt.update(transform: (Int) -> Int): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return
    }
}

/**
 * Atomically updates the value of this [AtomicInt] with the value obtained by
 * calling [transform] on the current value, returning the value replaced by
 * the updated one. [transform] may be invoked more than once when the value is
 * concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicInt.fetchAndUpdate(transform: (Int) -> Int): Int {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return old
    }
}

/**
 * Atomically updates the value of this [AtomicInt] with the value obtained by
 * calling [transform] on the current value, returning the new value.
 * [transform] may be invoked more than once when the value is concurrently
 * updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicInt.updateAndFetch(transform: (Int) -> Int): Int {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        val newValue = transform(old)
        if (compareAndSet(old, newValue)) return newValue
    }
}

/**
 * Atomically updates the value of this [AtomicLong] with the value obtained by
 * calling [transform] on the current value. [transform] may be invoked more
 * than once when the value is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLong.update(transform: (Long) -> Long): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return
    }
}

/**
 * Atomically updates the value of this [AtomicLong] with the value obtained by
 * calling [transform] on the current value, returning the value replaced by
 * the updated one. [transform] may be invoked more than once when the value is
 * concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLong.fetchAndUpdate(transform: (Long) -> Long): Long {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return old
    }
}

/**
 * Atomically updates the value of this [AtomicLong] with the value obtained by
 * calling [transform] on the current value, returning the new value.
 * [transform] may be invoked more than once when the value is concurrently
 * updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun AtomicLong.updateAndFetch(transform: (Long) -> Long): Long {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        val newValue = transform(old)
        if (compareAndSet(old, newValue)) return newValue
    }
}

/**
 * Atomically updates the value of this [AtomicReference] with the value
 * obtained by calling [transform] on the current value. [transform] may be
 * invoked more than once when the value is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicReference<T>.update(transform: (T) -> T): Unit {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return
    }
}

/**
 * Atomically updates the value of this [AtomicReference] with the value
 * obtained by calling [transform] on the current value, returning the value
 * replaced by the updated one. [transform] may be invoked more than once when
 * the value is concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicReference<T>.fetchAndUpdate(transform: (T) -> T): T {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        if (compareAndSet(old, transform(old))) return old
    }
}

/**
 * Atomically updates the value of this [AtomicReference] with the value
 * obtained by calling [transform] on the current value, returning the new
 * value. [transform] may be invoked more than once when the value is
 * concurrently updated.
 */
@SinceKotlin("2.2")
@ExperimentalAtomicApi
@InlineOnly
public actual inline fun <T> AtomicReference<T>.updateAndFetch(transform: (T) -> T): T {
    contract {
        callsInPlace(transform, InvocationKind.AT_LEAST_ONCE)
    }
    while (true) {
        val old = load()
        val newValue = transform(old)
        if (compareAndSet(old, newValue)) return newValue
    }
}
