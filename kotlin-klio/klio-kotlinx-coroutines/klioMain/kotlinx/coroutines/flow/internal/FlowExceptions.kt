// Bespoke klio platform layer: Flow-internal cancellation signals.

package kotlinx.coroutines.flow.internal

import kotlinx.coroutines.CancellationException

internal actual class AbortFlowException actual constructor(
    actual val owner: Any
) : CancellationException("Flow was aborted, no more elements needed")

internal actual class ChildCancelledException actual constructor()
    : CancellationException("Child of the scoped flow was cancelled")
