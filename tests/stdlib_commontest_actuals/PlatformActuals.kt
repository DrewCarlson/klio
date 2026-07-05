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
public val regexSplitUnicodeCodePointHandling: Boolean get() = true

// The commonTest backreference-handling enum + descriptor live in
// `common/test/testUtils.kt`, which the klio harness does not load (it walks
// `stdlib/test`, not `stdlib/common/test`); define them here so the regex tests
// resolve them. How KLIO's regex engine resolves invalid/edge-case
// backreferences (verified against its behavior): a backreference to a
// not-yet-defined, enclosing, or non-existent NUMBERED group matches the empty
// string (the expression is effectively ignored); a `\k<name>` to a
// missing/forward NAMED group is a literal that fails to match; `\0` is an
// octal NUL literal, so a "group zero" reference matches nothing. A trailing
// extra digit of a numbered backreference is captured at the largest valid index.
public enum class HandlingOption {
    MATCH_NOTHING, THROW, IGNORE_BACK_REFERENCE_EXPRESSION
}

public object BackReferenceHandling {
    val captureLargestValidIndex: Boolean get() = true
    val notYetDefinedGroup: HandlingOption = HandlingOption.IGNORE_BACK_REFERENCE_EXPRESSION
    val notYetDefinedNamedGroup: HandlingOption = HandlingOption.MATCH_NOTHING
    val enclosingGroup: HandlingOption = HandlingOption.IGNORE_BACK_REFERENCE_EXPRESSION
    val nonExistentGroup: HandlingOption = HandlingOption.IGNORE_BACK_REFERENCE_EXPRESSION
    val nonExistentNamedGroup: HandlingOption = HandlingOption.MATCH_NOTHING
    val groupZero: HandlingOption = HandlingOption.MATCH_NOTHING
}
