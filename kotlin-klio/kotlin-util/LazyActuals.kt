// klio `actual`s for the `kotlin.lazy` factories.
//
// klio runs real worker threads, so the default mode (and explicit
// SYNCHRONIZED / PUBLICATION) must initialize at most once under
// contention, matching the JVM actual: `KlioSynchronizedLazyImpl`
// holds the instance's monitor (`kotlin.synchronized`, the host's
// per-object reentrant lock) across the check-compute-publish, so two
// workers racing on `value` run the initializer exactly once and both
// observe the published result. PUBLICATION's weaker contract (the
// initializer may run multiple times, first result published) is
// satisfied by the same once-only implementation. Only explicit
// `LazyThreadSafetyMode.NONE` gets the unsynchronized upstream
// `UnsafeLazyImpl`.

package kotlin

public actual fun <T> lazy(initializer: () -> T): Lazy<T> = KlioSynchronizedLazyImpl(initializer)

public actual fun <T> lazy(mode: LazyThreadSafetyMode, initializer: () -> T): Lazy<T> =
    when (mode) {
        LazyThreadSafetyMode.NONE -> UnsafeLazyImpl(initializer)
        else -> KlioSynchronizedLazyImpl(initializer)
    }

public actual fun <T> lazy(lock: Any?, initializer: () -> T): Lazy<T> =
    KlioSynchronizedLazyImpl(initializer)

internal class KlioSynchronizedLazyImpl<out T>(initializer: () -> T) : Lazy<T> {
    private var initializer: (() -> T)? = initializer
    private var _value: Any? = UNINITIALIZED_VALUE

    override val value: T
        get() = kotlin.synchronized(this) {
            if (_value === UNINITIALIZED_VALUE) {
                _value = initializer!!()
                initializer = null
            }
            @Suppress("UNCHECKED_CAST")
            _value as T
        }

    override fun isInitialized(): Boolean = _value !== UNINITIALIZED_VALUE

    override fun toString(): String =
        if (isInitialized()) value.toString() else "Lazy value not initialized yet."
}
