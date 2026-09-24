/*
 * klio-authored declaration of `kotlin.concurrent.thread`, the JVM stdlib's
 * thread builder. It is a header: the body is the host's, and the declaration
 * exists so the symbol table can name the callable and the `klio.Thread`
 * handle it returns the way it names every other one.
 */
package kotlin.concurrent

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
