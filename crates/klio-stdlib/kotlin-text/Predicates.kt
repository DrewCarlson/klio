// klio commonMain shipment of kotlin.text emptiness / blankness
// predicates. Verbatim excerpts from
// kotlin/libraries/stdlib/src/kotlin/text/Strings.kt — these are
// the standard `CharSequence` extensions every Kotlin program
// expects to find on a bare `String`.

package kotlin.text

import kotlin.contracts.InvocationKind
import kotlin.contracts.contract

public inline fun CharSequence.isEmpty(): Boolean = length == 0

public inline fun CharSequence.isNotEmpty(): Boolean = length > 0

public fun CharSequence.isBlank(): Boolean = all { it.isWhitespace() }

public inline fun CharSequence.isNotBlank(): Boolean = !isBlank()

public inline fun <C, R> C.ifEmpty(defaultValue: () -> R): R where C : CharSequence, C : R {
    contract { callsInPlace(defaultValue, InvocationKind.AT_MOST_ONCE) }
    return if (isEmpty()) defaultValue() else this
}

public inline fun <C, R> C.ifBlank(defaultValue: () -> R): R where C : CharSequence, C : R {
    contract { callsInPlace(defaultValue, InvocationKind.AT_MOST_ONCE) }
    return if (isBlank()) defaultValue() else this
}
