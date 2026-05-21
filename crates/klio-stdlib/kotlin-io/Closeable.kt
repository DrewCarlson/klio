// klio commonMain shipment of `AutoCloseable.use`.
//
// The upstream commonMain declaration is `public expect inline fun`
// with a per-platform body — JVM has the suppressed-exception path,
// Native has a simple try/finally. klio is single-threaded with a
// straight finally semantics, so we ship the common-shape body
// directly here.

package kotlin

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract

public inline fun <T : AutoCloseable?, R> T.use(block: (T) -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    try {
        return block(this)
    } finally {
        this?.close()
    }
}
