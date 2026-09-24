// Bespoke klio platform layer: cancellation exception hierarchy.
// klio has no stack-trace recovery machinery, so no recovery flag.

package kotlinx.coroutines

// The cause travels through the constructor, as it does on the JVM through
// `initCause`: the internal constructor takes a `Unit` marker so it cannot
// clash with the `CancellationException(message, cause)` factory below.
public actual open class CancellationException internal constructor(
    message: String?,
    cause: Throwable?,
    @Suppress("UNUSED_PARAMETER") withCause: Unit,
) : IllegalStateException(message, cause) {
    public actual constructor(message: String?) : this(message, null, Unit)
}

public actual fun CancellationException(
    message: String?,
    cause: Throwable?
): CancellationException = CancellationException(message, cause, Unit)

internal actual class JobCancellationException actual constructor(
    message: String,
    cause: Throwable?,
    job: Job
) : CancellationException(message, cause, Unit) {
    internal actual val job: Job = job
    override fun toString(): String = "${super.toString()}; job=$job"
}

internal actual val RECOVER_STACK_TRACES: Boolean = false
