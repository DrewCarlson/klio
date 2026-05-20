package kotlinx.coroutines.internal

@InternalCoroutinesApi
public actual typealias SynchronizedObject = Any

// Real monitor protection. The body runs while holding a per-object
// OS mutex keyed on the lock's reference identity, so concurrent
// `Dispatchers.Default` workers contending on the same lock are
// mutually excluded. The cooperative pump observes the same
// semantics single-threaded. The host binding picks the same
// monitor as the `kotlin.synchronized` binding (one global table
// keyed on the lock's identity), so atomicfu, kotlinx-coroutines
// internals, and user `synchronized(lock) { … }` calls all share one
// monitor.
//
// Deliberately NOT `inline`: inlining lets klio's lookup of
// `synchronized` by simple name hijack the user's bare
// `synchronized(...)` call (default-import resolves to
// `kotlin.synchronized` but the inline-fn-AST table is keyed by
// simple name and would otherwise splice the inline body in
// instead, never reaching the host monitor binding). The body
// itself is unreachable — `klio-kotlinx-coroutines`'s host binding
// table intercepts the call before AST evaluation.
@PublishedApi
internal actual fun <T> synchronizedImpl(lock: SynchronizedObject, block: () -> T): T =
    block()
