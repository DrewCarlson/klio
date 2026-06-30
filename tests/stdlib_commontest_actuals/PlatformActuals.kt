/*
 * KLIO actuals for the stdlib commonTest infrastructure. These satisfy the
 * `expect` declarations in `kotlin/libraries/stdlib/test/testUtils.kt` so the
 * common test sources resolve and run through `klio test`. KLIO is reported as
 * `Native`: it is a from-scratch interpreter with no JVM/JS host facilities, so
 * the JVM/Native-gated common behavior runs and the JS/Wasm-specific gates skip.
 */
package test

import kotlin.test.assertEquals

actual val TestPlatform.Companion.current: TestPlatform get() = TestPlatform.Native

/** Asserts that two values have the same runtime type (or are both null). The
 *  platform `testUtils` actuals compare host class objects; KLIO compares the
 *  reflected `KClass`. */
public fun assertTypeEquals(expected: Any?, actual: Any?) {
    assertEquals(expected?.let { it::class.qualifiedName }, actual?.let { it::class.qualifiedName })
}

// Regex / numeric platform-capability flags the common tests gate on. KLIO's
// regex engine accepts escaping an arbitrary character and octal character
// literals (Java dialect); its `Float` arithmetic enforces the 32-bit range.
public val isFloat32RangeEnforced: Boolean = true
public val supportsOctalLiteralInRegex: Boolean get() = true
public val supportsEscapeAnyCharInRegex: Boolean get() = true
public val regexSplitUnicodeCodePointHandling: Boolean get() = false
