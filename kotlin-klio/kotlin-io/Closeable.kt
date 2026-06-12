// klio commonMain shipment of `AutoCloseable.use`.
//
// The upstream commonMain declaration is `public expect inline fun`
// with a per-platform body — JVM has the suppressed-exception path,
// Native has a simple try/finally. klio does not surface
// suppressed-exception chains, so it ships the Native-shaped
// try/finally body directly here.

package kotlin

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract

public actual inline fun <T : AutoCloseable?, R> T.use(block: (T) -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    try {
        return block(this)
    } finally {
        this?.close()
    }
}

public actual inline fun AutoCloseable(crossinline closeAction: () -> Unit): AutoCloseable = object : AutoCloseable {
    override fun close() = closeAction()
}
