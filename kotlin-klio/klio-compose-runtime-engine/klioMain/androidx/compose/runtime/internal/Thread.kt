// klio actuals for the runtime's thread-identity internals. The snapshot core
// keys per-thread snapshot state on `currentThreadId`; there is no distinguished
// "main" thread in klio, so `MainThreadId` is a sentinel no real thread reports
// and every thread takes the map-backed path.

package androidx.compose.runtime.internal

internal fun __compose_currentThreadId(): Long =
    error("intrinsic androidx.compose.runtime.__compose_currentThreadId not installed")

internal actual val MainThreadId: Long = -1L

internal actual fun currentThreadId(): Long = __compose_currentThreadId()

internal actual fun currentThreadName(): String = "thread-" + currentThreadId()
