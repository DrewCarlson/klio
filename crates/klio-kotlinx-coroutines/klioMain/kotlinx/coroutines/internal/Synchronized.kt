package kotlinx.coroutines.internal

@InternalCoroutinesApi
public actual typealias SynchronizedObject = Any

// klio's lowerer shadows the bare `synchronized` simple name with
// the `kotlin.synchronized` host binding (see klio-interp-ir's
// build pass), so a bare `synchronized(lock) { … }` call resolves
// to the real per-object OS monitor through the host binding —
// never into this implementation. Pack internals that go through
// the public `kotlinx.coroutines.internal.synchronized` inline
// builder land on the same binding for the same reason. The body
// here matches the JS/WASM actual shape (`block()`) so the source
// still type-checks; it is unreachable in practice.
@PublishedApi
internal actual inline fun <T> synchronizedImpl(lock: SynchronizedObject, block: () -> T): T =
    block()
