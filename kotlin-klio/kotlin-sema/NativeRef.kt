// Kotlin/Native's weak references, cleaners and collector entry point, over
// klio's tracing collector. The public declarations are Kotlin/Native's; the
// weak cell, the cleaner registry and the collection are the host's.

package kotlin.native.ref

import kotlin.experimental.ExperimentalNativeApi

/**
 * A reference to [referred] that does not keep it alive: once nothing else
 * reaches it, a collection clears the reference and [get] returns null.
 */
@ExperimentalNativeApi
public class WeakReference<T : Any> {
    public constructor(referred: T) {
        cell = __klio_weakNew(referred)
    }

    private var cell: Any?

    public fun clear() {
        cell = null
    }

    @Suppress("UNCHECKED_CAST")
    public fun get(): T? {
        val c = cell ?: return null
        return __klio_weakGet(c) as T?
    }

    public val value: T?
        get() = this.get()
}

/**
 * The handle [createCleaner] returns. Its cleanup action runs, on a cleaner
 * thread, after a collection finds the handle unreachable.
 */
@ExperimentalNativeApi
@SinceKotlin("1.9")
public sealed interface Cleaner

/**
 * Runs [cleanupAction] on [resource] once the returned [Cleaner] is garbage.
 * The action must not capture the object the cleaner is stored in, or that
 * object stays reachable and the action never runs. An exception the action
 * throws is dropped.
 */
@ExperimentalNativeApi
@SinceKotlin("1.9")
public fun <T> createCleaner(resource: T, cleanupAction: (resource: T) -> Unit): Cleaner {
    val job = cleanupJob(resource, cleanupAction)
    val cleaner = CleanerImpl(job)
    if (__klio_cleanerRegister(cleaner, job)) {
        kotlin.concurrent.thread(isDaemon = true, name = "Cleaner worker") { runCleanups() }
    }
    return cleaner
}

// Holds the job while the cleaner lives; once a collection frees the
// cleaner, the host keeps the job until the cleaner thread has run it.
@ExperimentalNativeApi
private class CleanerImpl(@Suppress("unused") private val job: () -> Unit) : Cleaner

// Built apart from `createCleaner` so the job captures the resource and the
// action only, never the cleaner it belongs to.
private fun <T> cleanupJob(resource: T, cleanupAction: (T) -> Unit): () -> Unit = {
    try {
        cleanupAction(resource)
    } catch (_: Throwable) {
    }
}

private fun runCleanups() {
    while (true) {
        val job = __klio_cleanerTake() ?: return
        @Suppress("UNCHECKED_CAST")
        (job as () -> Unit)()
    }
}

internal external fun __klio_weakNew(referred: Any): Any
internal external fun __klio_weakGet(cell: Any): Any?
internal external fun __klio_cleanerRegister(owner: Any, job: () -> Unit): Boolean
internal external fun __klio_cleanerTake(): Any?
