/*
 * A coroutine context element that carries an MDC context map, as
 * kotlinx-coroutines-slf4j's MDCContext does on the JVM: whenever the
 * coroutine runs, on any thread, the thread's MDC is the element's map, and
 * the thread's own MDC comes back when the coroutine suspends or finishes.
 * Changes a coroutine makes with `MDC.put` are not carried across a
 * suspension; start a new `withContext(MDCContext())` to keep them.
 */

package klio.logging

import kotlinx.coroutines.ThreadContextElement
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

public typealias MDCContextMap = Map<String, String>?

public class MDCContext(
    /** The MDC entries the coroutine runs with. */
    public val contextMap: MDCContextMap = MDC.getCopyOfContextMap()
) : ThreadContextElement<MDCContextMap>, AbstractCoroutineContextElement(Key) {

    public companion object Key : CoroutineContext.Key<MDCContext>

    override fun updateThreadContext(context: CoroutineContext): MDCContextMap {
        val oldState = MDC.getCopyOfContextMap()
        setCurrent(contextMap)
        return oldState
    }

    override fun restoreThreadContext(context: CoroutineContext, oldState: MDCContextMap) {
        setCurrent(oldState)
    }

    private fun setCurrent(contextMap: MDCContextMap) {
        if (contextMap == null) {
            MDC.clear()
        } else {
            MDC.setContextMap(contextMap)
        }
    }
}
