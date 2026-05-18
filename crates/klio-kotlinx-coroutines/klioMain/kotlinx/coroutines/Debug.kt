// Bespoke klio platform layer: debug/identity helpers + Runnable.
// Assertions are off (matches a JVM run without -ea, the parity
// target). hexAddress/classSimpleName are best-effort identity
// strings — only used in debug output, never on a parity path.

package kotlinx.coroutines

internal actual val DEBUG: Boolean = false

internal actual val Any.hexAddress: String
    get() = this.hashCode().toString(16)

internal actual val Any.classSimpleName: String
    get() = this::class.simpleName ?: "Any"

internal actual fun assert(value: () -> Boolean) {
}

public actual fun interface Runnable {
    public actual fun run()
}
