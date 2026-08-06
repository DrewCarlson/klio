/*
 * klio-authored declarations for the thread surface the interpreter serves.
 *
 * The upstream declarations live in JVM platform files klio does not consume,
 * so resolution could reach `thread` and the handle it returns only through a
 * runtime name probe. These are headers: the bodies are the host's, and the
 * declaration exists so the symbol table can name the callable and its return
 * type the way it names every other one.
 */
package kotlin.concurrent

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
}

/**
 * Run [block] on its own thread and return a handle to it.
 */
public external fun thread(
    start: Boolean = true,
    isDaemon: Boolean = false,
    contextClassLoader: Any? = null,
    name: String? = null,
    priority: Int = -1,
    block: () -> Unit,
): Thread
