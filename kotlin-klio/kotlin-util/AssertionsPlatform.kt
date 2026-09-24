/*
 * The JVM stdlib's `assert`. A failed assertion throws only when runtime
 * assertions are on, which on the JVM takes the `-ea` option; a program run
 * does not pass it, so they are off, as they are for `kotlin` and `java`.
 */
package kotlin

@PublishedApi
internal object _Assertions {
    @PublishedApi
    internal val ENABLED: Boolean = false
}

/**
 * Throws an [AssertionError] if the [value] is false
 * and runtime assertions have been enabled.
 */
@kotlin.internal.InlineOnly
public inline fun assert(value: Boolean) {
    assert(value) { "Assertion failed" }
}

/**
 * Throws an [AssertionError] calculated by [lazyMessage] if the [value] is false
 * and runtime assertions have been enabled.
 */
@kotlin.internal.InlineOnly
public inline fun assert(value: Boolean, lazyMessage: () -> Any) {
    if (_Assertions.ENABLED) {
        if (!value) {
            val message = lazyMessage()
            throw AssertionError(message)
        }
    }
}
