// Bespoke klio platform layer: cancellation exception hierarchy.
// klio has no stack-trace recovery machinery, so no recovery flag.

package kotlinx.coroutines

// As on the JVM and native, the coroutines' CancellationException is the
// stdlib's: `catch (e: kotlin.coroutines.cancellation.CancellationException)`
// catches a job's cancellation, and `Job.cancel` takes either name. The
// stdlib class takes its cause through its `(message, cause)` constructor.
public actual typealias CancellationException = kotlin.coroutines.cancellation.CancellationException

@Suppress("INVISIBLE_MEMBER", "INVISIBLE_REFERENCE")
@kotlin.internal.LowPriorityInOverloadResolution
public actual fun CancellationException(message: String?, cause: Throwable?): CancellationException =
    CancellationException(message, cause)

internal actual class JobCancellationException actual constructor(
    message: String,
    cause: Throwable?,
    job: Job
) : CancellationException(message, cause) {
    internal actual val job: Job = job
    override fun toString(): String = "${super.toString()}; job=$job"
}

internal actual val RECOVER_STACK_TRACES: Boolean = false
