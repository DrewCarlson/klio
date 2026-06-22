/*
 * KLIO actuals for the stdlib commonTest infrastructure. These satisfy the
 * `expect` declarations in `kotlin/libraries/stdlib/test/testUtils.kt` so the
 * common test sources resolve and run through `klio test`. KLIO is reported as
 * `Native`: it is a from-scratch interpreter with no JVM/JS host facilities, so
 * the JVM/Native-gated common behavior runs and the JS/Wasm-specific gates skip.
 */
package test

actual val TestPlatform.Companion.current: TestPlatform get() = TestPlatform.Native
