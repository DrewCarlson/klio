/*
 * The thread surface the interpreter serves: the handle
 * `kotlin.concurrent.thread` returns and `currentThread` / `sleep` on its
 * companion. These are headers: the bodies are the host's.
 */
package klio

public external class Thread {
    /** A stable per-thread name; two reads on one thread agree. */
    public val name: String

    /** Whether the thread has not yet finished. */
    public val isAlive: Boolean

    /**
     * Wait for the thread to finish. The body's writes are visible to the
     * caller once this returns. Idempotent.
     */
    public fun join()

    public fun start()

    public fun interrupt()

    public companion object {
        /** The handle of the calling thread. */
        public fun currentThread(): Thread

        /** Suspend the calling thread for [millis] milliseconds. */
        public fun sleep(millis: Long)
    }
}
