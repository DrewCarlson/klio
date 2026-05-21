// klio commonMain shipment of `kotlin.Lazy<T>` + `lazy { ... }` /
// `lazyOf(v)`. klio runs single-threaded so the unsynchronized
// impl is sufficient for every `LazyThreadSafetyMode`. The
// `Lazy<T>.getValue` operator extension below is what makes
// `val x: T by lazy { … }` route through the Lazy instance.

package kotlin

import kotlin.reflect.KProperty

public interface Lazy<out T> {
    public val value: T
    public fun isInitialized(): Boolean
}

public inline operator fun <T> Lazy<T>.getValue(thisRef: Any?, property: KProperty<*>): T = value

public fun <T> lazy(initializer: () -> T): Lazy<T> = UnsafeLazyImpl(initializer)

public fun <T> lazyOf(value: T): Lazy<T> = InitializedLazyImpl(value)

private class UnsafeLazyImpl<out T>(initializer: () -> T) : Lazy<T> {
    private var initializer: (() -> T)? = initializer
    // klio note: the upstream impl stores an `UNINITIALIZED_VALUE`
    // singleton in `_value` and checks `_value === UNINITIALIZED_VALUE`.
    // klio's top-level property initialiser runs in a separate eval
    // context whose `object` identity does not match singletons read
    // from a main-thread call site, so the upstream form mis-detects
    // an initialised lazy as un-initialised at top level. A boolean
    // flag side-steps the identity check entirely and matches the
    // observable semantics exactly.
    private var initialized: Boolean = false
    private var _value: Any? = null

    override val value: T
        get() {
            if (!initialized) {
                _value = initializer!!()
                initializer = null
                initialized = true
            }
            @Suppress("UNCHECKED_CAST")
            return _value as T
        }

    override fun isInitialized(): Boolean = initialized

    override fun toString(): String =
        if (initialized) value.toString() else "Lazy value not initialized yet."
}

private class InitializedLazyImpl<out T>(override val value: T) : Lazy<T> {
    override fun isInitialized(): Boolean = true
    override fun toString(): String = value.toString()
}
