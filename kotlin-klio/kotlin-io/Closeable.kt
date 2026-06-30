// klio commonMain shipment of `AutoCloseable.use`.
//
// The upstream commonMain declaration is `public expect inline fun` with a
// per-platform body. This matches the full semantics: the block's exception
// propagates, and an exception thrown by `close()` while unwinding is added to
// the block exception's suppressed list rather than replacing it.

package kotlin

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract

public actual inline fun <T : AutoCloseable?, R> T.use(block: (T) -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    var exception: Throwable? = null
    try {
        return block(this)
    } catch (e: Throwable) {
        exception = e
        throw e
    } finally {
        when {
            this == null -> {}
            exception == null -> close()
            else ->
                try {
                    close()
                } catch (closeException: Throwable) {
                    exception.addSuppressed(closeException)
                }
        }
    }
}

public actual inline fun AutoCloseable(crossinline closeAction: () -> Unit): AutoCloseable = object : AutoCloseable {
    override fun close() = closeAction()
}
