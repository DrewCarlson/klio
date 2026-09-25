// The "current thread" animation-core's commonMain expects: a stable
// per-thread identity token, so thread-change detection observes real thread
// hops.
package androidx.compose.animation.core

// Per-thread identity tokens keyed on the calling thread's stable name
// (klio's `Thread.currentThread().name` is unique per OS thread), so
// repeated calls on one thread return the SAME object and a thread hop
// returns a different one — the identity contract thread-change
// detection compares against.
private val threadTokens = HashMap<String, Any>()

internal actual fun getCurrentThread(): Any = kotlin.synchronized(threadTokens) {
    threadTokens.getOrPut(Thread.currentThread().name) { Any() }
}
