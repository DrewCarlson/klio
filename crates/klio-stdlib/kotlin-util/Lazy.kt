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

private object UNINITIALIZED_VALUE

private class UnsafeLazyImpl<out T>(initializer: () -> T) : Lazy<T> {
    private var initializer: (() -> T)? = initializer
    private var _value: Any? = UNINITIALIZED_VALUE

    override val value: T
        get() {
            if (_value === UNINITIALIZED_VALUE) {
                _value = initializer!!()
                initializer = null
            }
            @Suppress("UNCHECKED_CAST")
            return _value as T
        }

    override fun isInitialized(): Boolean = _value !== UNINITIALIZED_VALUE

    override fun toString(): String =
        if (isInitialized()) value.toString() else "Lazy value not initialized yet."
}

private class InitializedLazyImpl<out T>(override val value: T) : Lazy<T> {
    override fun isInitialized(): Boolean = true
    override fun toString(): String = value.toString()
}
