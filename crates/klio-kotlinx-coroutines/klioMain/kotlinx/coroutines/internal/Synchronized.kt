package kotlinx.coroutines.internal

@InternalCoroutinesApi
public actual typealias SynchronizedObject = Any

// klio runs one cooperative, non-preemptive scheduler per
// `runBlocking`: a block runs to completion before any other
// coroutine is resumed, so a monitor reduces to running the block
// in place. Mutual exclusion across `launch(Dispatchers.Default)`
// children therefore holds without an OS lock.
@PublishedApi
internal actual inline fun <T> synchronizedImpl(lock: SynchronizedObject, block: () -> T): T =
    block()
