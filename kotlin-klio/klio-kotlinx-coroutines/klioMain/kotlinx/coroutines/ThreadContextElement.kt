// klio declaration of kotlinx-coroutines' ThreadContextElement (upstream ships
// it in the JVM source set). The dispatch seams (`withCoroutineContext` /
// `withContinuationContext` in ContextActuals.kt) call updateThreadContext
// before running a dispatched block and restoreThreadContext after, so an
// element such as compose's SnapshotContextElement can make per-resume state
// (the current snapshot) follow its coroutine.

package kotlinx.coroutines

import kotlin.coroutines.CoroutineContext

public interface ThreadContextElement<S> : CoroutineContext.Element {
    public fun updateThreadContext(context: CoroutineContext): S

    public fun restoreThreadContext(context: CoroutineContext, oldState: S)
}
