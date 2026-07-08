// Assertion helpers the runtime's data structures use. Upstream declares these
// in Composer.kt / Preconditions.kt; klio ships its own so the standalone
// structures resolve them without the compiler-coupled Composer.

package androidx.compose.runtime

internal fun throwIllegalArgumentException(message: String) {
    throw IllegalArgumentException(message)
}

internal inline fun requirePrecondition(value: Boolean, lazyMessage: () -> String) {
    if (!value) throwIllegalArgumentException(lazyMessage())
}

internal fun throwIllegalStateException(message: String) {
    throw IllegalStateException(message)
}

internal inline fun checkPrecondition(value: Boolean, lazyMessage: () -> String) {
    if (!value) throwIllegalStateException(lazyMessage())
}

internal inline fun checkPrecondition(value: Boolean) {
    checkPrecondition(value) { "Check failed." }
}

internal inline fun requirePreconditionNotNull(value: Any?, lazyMessage: () -> String) {
    if (value == null) throwIllegalArgumentException(lazyMessage())
}

internal fun composeImmediateRuntimeError(message: String): Nothing {
    throw ComposeRuntimeError("Compose Runtime internal error. Unexpected or incorrect use of the Compose internal runtime API ($message)")
}

internal fun composeRuntimeError(message: String): Nothing {
    throw ComposeRuntimeError("Compose Runtime internal error. Unexpected or incorrect use of the Compose internal runtime API ($message)")
}

internal class ComposeRuntimeError(override val message: String) : IllegalStateException(message)

internal inline fun runtimeCheck(value: Boolean, lazyMessage: () -> String) {
    if (!value) composeRuntimeError(lazyMessage())
}

internal inline fun runtimeCheck(value: Boolean) {
    runtimeCheck(value) { "Check failed" }
}
