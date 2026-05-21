// klio commonMain shipment of kotlin.* scope functions.
//
// These are the exact upstream Kotlin definitions of the eight scope
// functions from kotlin/libraries/stdlib/src/kotlin/util/Standard.kt.
// They live here as a focused excerpt so the embedded stdlib pack
// can ship the real common-Kotlin builder code without dragging in
// the full file's NotImplementedError / TODO declarations (TODO is
// supplied through the host-binding path for now).

package kotlin

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract

public inline fun <R> run(block: () -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    return block()
}

public inline fun <T, R> T.run(block: T.() -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    return this.block()
}

public inline fun <T, R> with(receiver: T, block: T.() -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    return receiver.block()
}

public inline fun <T> T.apply(block: T.() -> Unit): T {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    this.block()
    return this
}

public inline fun <T> T.also(block: (T) -> Unit): T {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    block(this)
    return this
}

public inline fun <T, R> T.let(block: (T) -> R): R {
    contract { callsInPlace(block, InvocationKind.EXACTLY_ONCE) }
    return block(this)
}

public inline fun <T> T.takeIf(predicate: (T) -> Boolean): T? {
    contract { callsInPlace(predicate, InvocationKind.EXACTLY_ONCE) }
    return if (predicate(this)) this else null
}

public inline fun <T> T.takeUnless(predicate: (T) -> Boolean): T? {
    contract { callsInPlace(predicate, InvocationKind.EXACTLY_ONCE) }
    return if (!predicate(this)) this else null
}

public inline fun repeat(times: Int, action: (Int) -> Unit) {
    contract { callsInPlace(action) }
    for (index in 0 until times) {
        action(index)
    }
}
