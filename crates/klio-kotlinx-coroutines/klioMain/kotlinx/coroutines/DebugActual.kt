// Platform `actual`s for the curated upstream `Debug.common.kt`
// expects. klio has no debug-probes agent and runs single-threaded,
// so debug instrumentation is inert: DEBUG is off, identity/address
// rendering is a stable best-effort string, and the internal `assert`
// is a no-op (assertions are not part of the runnable contract here).

package kotlinx.coroutines

internal actual val DEBUG: Boolean = false

internal actual val Any.hexAddress: String
    get() = "0"

internal actual val Any.classSimpleName: String
    get() = "Unknown"

internal actual fun assert(value: () -> Boolean) {}
