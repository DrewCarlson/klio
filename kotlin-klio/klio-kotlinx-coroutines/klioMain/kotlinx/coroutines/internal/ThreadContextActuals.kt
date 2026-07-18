// Thread-context capture for dispatched coroutine blocks: counts the
// ThreadContextElements of a context and updates/restores them around each
// dispatched run. Ported from upstream's JVM internal/ThreadContext.kt; the
// klio pump runs blocks cooperatively, so "thread" state here is whatever the
// element itself manages (compose's SnapshotContextElement swaps the current
// snapshot).

package kotlinx.coroutines.internal

import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.ThreadContextElement

internal val NO_THREAD_ELEMENTS = Symbol("NO_THREAD_ELEMENTS")

private class ThreadState(val context: CoroutineContext, n: Int) {
    private val values = arrayOfNulls<Any>(n)
    private val elements = arrayOfNulls<ThreadContextElement<Any?>>(n)
    private var i = 0

    @Suppress("UNCHECKED_CAST")
    fun append(element: ThreadContextElement<*>, value: Any?) {
        values[i] = value
        elements[i++] = element as ThreadContextElement<Any?>
    }

    fun restore(context: CoroutineContext) {
        for (i in elements.indices.reversed()) {
            elements[i]!!.restoreThreadContext(context, values[i])
        }
    }
}

private val countAll = fun(countOrElement: Any?, element: CoroutineContext.Element): Any? {
    if (element is ThreadContextElement<*>) {
        val inCount = countOrElement as? Int ?: 1
        return if (inCount == 0) element else inCount + 1
    }
    return countOrElement
}

private val findOne =
    fun(found: ThreadContextElement<*>?, element: CoroutineContext.Element): ThreadContextElement<*>? {
        if (found != null) return found
        return element as? ThreadContextElement<*>
    }

private val updateState = fun(state: ThreadState, element: CoroutineContext.Element): ThreadState {
    if (element is ThreadContextElement<*>) {
        state.append(element, element.updateThreadContext(state.context))
    }
    return state
}

internal fun updateThreadContext(context: CoroutineContext, countOrElement: Any?): Any? {
    @Suppress("NAME_SHADOWING")
    val countOrElement = countOrElement ?: threadContextElements(context)
    return when {
        countOrElement == 0 -> NO_THREAD_ELEMENTS
        countOrElement is Int -> context.fold(ThreadState(context, countOrElement), updateState)
        else -> {
            @Suppress("UNCHECKED_CAST")
            val element = countOrElement as ThreadContextElement<Any?>
            element.updateThreadContext(context)
        }
    }
}

internal fun restoreThreadContext(context: CoroutineContext, oldState: Any?) {
    when {
        oldState === NO_THREAD_ELEMENTS -> return
        oldState is ThreadState -> oldState.restore(context)
        else -> {
            @Suppress("UNCHECKED_CAST")
            val element = context.fold(null, findOne) as ThreadContextElement<Any?>
            element.restoreThreadContext(context, oldState)
        }
    }
}
