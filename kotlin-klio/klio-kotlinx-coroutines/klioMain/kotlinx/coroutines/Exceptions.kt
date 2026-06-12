// Bespoke klio platform layer: cancellation exception hierarchy.
// klio has no stack-trace recovery machinery, so no recovery flag.

package kotlinx.coroutines

public actual open class CancellationException actual constructor(
    message: String?
) : IllegalStateException(message)

public actual fun CancellationException(
    message: String?,
    cause: Throwable?
): CancellationException = CancellationException(message).apply {
    if (cause != null) initCause(cause)
}

internal actual class JobCancellationException actual constructor(
    message: String,
    cause: Throwable?,
    job: Job
) : CancellationException(message) {
    internal actual val job: Job = job
    init { if (cause != null) initCause(cause) }
    override fun toString(): String = "${super.toString()}; job=$job"
}

internal actual val RECOVER_STACK_TRACES: Boolean = false
