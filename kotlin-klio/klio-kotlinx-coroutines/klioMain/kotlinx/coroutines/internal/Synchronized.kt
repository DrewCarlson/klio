package kotlinx.coroutines.internal

@InternalCoroutinesApi
public actual typealias SynchronizedObject = Any

// klio's lowerer shadows the bare `synchronized` simple name with
// the `kotlin.synchronized` host binding (see klio-interp-ir's
// build pass), so a bare `synchronized(lock) { … }` call resolves
// to the real per-object OS monitor through the host binding.
// `kotlinx.coroutines.internal.synchronizedImpl` is itself bound
// natively to the same monitor table (see `synchronizedImpl` in the
// pack's `src/kotlinx_coroutines`), so even an explicit
// fully-qualified call observes real exclusion. The Kotlin body below stays as a defensive
// last-resort delegate to `kotlin.synchronized` so a caller who
// somehow reaches the AST body (binding not installed) still gets
// real serialization instead of a silent `block()` no-op.
@PublishedApi
internal actual inline fun <T> synchronizedImpl(lock: SynchronizedObject, block: () -> T): T =
    kotlin.synchronized(lock, block)
