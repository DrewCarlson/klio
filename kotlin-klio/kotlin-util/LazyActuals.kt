// klio `actual`s for the `kotlin.lazy` factories.
//
// klio runs real worker threads, so the default mode (and explicit
// SYNCHRONIZED / PUBLICATION) must initialize at most once under
// contention, matching the JVM actual: `KlioSynchronizedLazyImpl`
// reads its `@Volatile` value and, until it is published, holds the
// lock's monitor (`kotlin.synchronized`, the host's per-object
// reentrant lock; the instance itself unless `lazy(lock)` names one)
// across the check-compute-publish, so two workers racing on `value`
// run the initializer exactly once and both observe the published
// result. PUBLICATION's weaker contract (the initializer may run
// multiple times, first result published) is satisfied by the same
// once-only implementation. Only explicit `LazyThreadSafetyMode.NONE`
// gets the unsynchronized upstream `UnsafeLazyImpl`.

package kotlin

public actual fun <T> lazy(initializer: () -> T): Lazy<T> = KlioSynchronizedLazyImpl(initializer)

public actual fun <T> lazy(mode: LazyThreadSafetyMode, initializer: () -> T): Lazy<T> =
    when (mode) {
        LazyThreadSafetyMode.NONE -> UnsafeLazyImpl(initializer)
        else -> KlioSynchronizedLazyImpl(initializer)
    }

public actual fun <T> lazy(lock: Any?, initializer: () -> T): Lazy<T> =
    KlioSynchronizedLazyImpl(initializer, lock)

internal class KlioSynchronizedLazyImpl<out T>(initializer: () -> T, lock: Any? = null) : Lazy<T> {
    private var initializer: (() -> T)? = initializer

    @kotlin.concurrent.Volatile
    private var _value: Any? = UNINITIALIZED_VALUE

    private val lock = lock ?: this

    override val value: T
        get() {
            val v1 = _value
            if (v1 !== UNINITIALIZED_VALUE) {
                @Suppress("UNCHECKED_CAST")
                return v1 as T
            }
            return kotlin.synchronized(lock) {
                val v2 = _value
                if (v2 !== UNINITIALIZED_VALUE) {
                    @Suppress("UNCHECKED_CAST") (v2 as T)
                } else {
                    val typed = initializer!!()
                    _value = typed
                    initializer = null
                    typed
                }
            }
        }

    override fun isInitialized(): Boolean = _value !== UNINITIALIZED_VALUE

    override fun toString(): String =
        if (isInitialized()) value.toString() else "Lazy value not initialized yet."
}
