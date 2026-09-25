/*
 * The mapped diagnostic context: string entries attached to the current
 * thread, which a logger can add to what it writes. It stands where Ktor's
 * JVM plugins use org.slf4j.MDC, with the same operations. `MDCContext`
 * carries a copy into a coroutine and back onto whichever thread resumes it.
 */

package klio.logging

import klio.Thread

public object MDC {
    private val maps: HashMap<String, MutableMap<String, String>> = HashMap()

    private fun key(): String = Thread.currentThread().name

    /** Sets [key] to [value] in the current thread's context. */
    public fun put(key: String, value: String) {
        kotlin.synchronized(this) {
            maps.getOrPut(key()) { LinkedHashMap() }[key] = value
        }
    }

    /** The current thread's value for [key], or null. */
    public fun get(key: String): String? = kotlin.synchronized(this) { maps[key()]?.get(key) }

    /** Removes [key] from the current thread's context. */
    public fun remove(key: String) {
        kotlin.synchronized(this) {
            val thread = key()
            val map = maps[thread] ?: return
            map.remove(key)
            if (map.isEmpty()) maps.remove(thread)
        }
    }

    /** Removes every entry of the current thread's context. */
    public fun clear() {
        kotlin.synchronized(this) { maps.remove(key()) }
    }

    /** A copy of the current thread's context, or null when it has none. */
    public fun getCopyOfContextMap(): MutableMap<String, String>? =
        kotlin.synchronized(this) { maps[key()]?.let { LinkedHashMap(it) } }

    /** Replaces the current thread's context with a copy of [contextMap]. */
    public fun setContextMap(contextMap: Map<String, String>) {
        kotlin.synchronized(this) {
            val thread = key()
            if (contextMap.isEmpty()) maps.remove(thread) else maps[thread] = LinkedHashMap(contextMap)
        }
    }
}
