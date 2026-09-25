// klio actuals for the runtime's thread identity. The snapshot core keys
// per-thread snapshot state on `currentThreadId`; the host answers the calling
// thread's id.

package androidx.compose.runtime.internal

internal fun __compose_currentThreadId(): Long =
    error("intrinsic androidx.compose.runtime.__compose_currentThreadId not installed")

internal actual fun currentThreadId(): Long = __compose_currentThreadId()

internal actual fun currentThreadName(): String = "thread-" + currentThreadId()
