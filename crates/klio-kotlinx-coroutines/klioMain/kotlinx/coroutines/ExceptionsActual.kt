// Platform `actual`s for the curated upstream `Exceptions.common.kt`
// expects. klio runs single-threaded with no stacktrace-recovery
// agent, so cancellation is a plain exception hierarchy and stack
// recovery is disabled.

package kotlinx.coroutines

actual open class CancellationException actual constructor(
    message: String?,
) : IllegalStateException(message)

actual fun CancellationException(message: String?, cause: Throwable?): CancellationException =
    CancellationException(message).apply { initCause(cause) }

internal actual class JobCancellationException actual constructor(
    message: String,
    cause: Throwable?,
    internal actual val job: Job,
) : CancellationException(message) {
    init {
        if (cause != null) initCause(cause)
    }

    override fun toString(): String = "${super.toString()}; job=$job"
}

internal actual val RECOVER_STACK_TRACES: Boolean = false
