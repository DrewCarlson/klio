// klio commonMain shipment of kotlin.* precondition helpers.
//
// Verbatim excerpts of the four public precondition checks from
// kotlin/libraries/stdlib/src/kotlin/util/Preconditions.kt. The
// `error(message)` helper stays on the host-binding path for now.

package kotlin

import kotlin.contracts.contract

public inline fun require(value: Boolean): Unit {
    contract { returns() implies value }
    require(value) { "Failed requirement." }
}

public inline fun require(value: Boolean, lazyMessage: () -> Any): Unit {
    contract { returns() implies value }
    if (!value) {
        val message = lazyMessage()
        throw IllegalArgumentException(message.toString())
    }
}

public inline fun <T : Any> requireNotNull(value: T?): T {
    contract { returns() implies (value != null) }
    return requireNotNull(value) { "Required value was null." }
}

public inline fun <T : Any> requireNotNull(value: T?, lazyMessage: () -> Any): T {
    contract { returns() implies (value != null) }
    if (value == null) {
        val message = lazyMessage()
        throw IllegalArgumentException(message.toString())
    } else {
        return value
    }
}

public inline fun check(value: Boolean): Unit {
    contract { returns() implies value }
    if (!value) {
        throw IllegalStateException("Check failed.")
    }
}

public inline fun check(value: Boolean, lazyMessage: () -> Any): Unit {
    contract { returns() implies value }
    if (!value) {
        val message = lazyMessage()
        throw IllegalStateException(message.toString())
    }
}

public inline fun <T : Any> checkNotNull(value: T?): T {
    contract { returns() implies (value != null) }
    return checkNotNull(value) { "Required value was null." }
}

public inline fun <T : Any> checkNotNull(value: T?, lazyMessage: () -> Any): T {
    contract { returns() implies (value != null) }
    if (value == null) {
        val message = lazyMessage()
        throw IllegalStateException(message.toString())
    } else {
        return value
    }
}
