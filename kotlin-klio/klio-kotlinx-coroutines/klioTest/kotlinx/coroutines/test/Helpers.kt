// klio-authored platform actual for kotlinx-coroutines-test's own commonTest
// helpers (upstream `native/test/Helpers.kt`): a test body runs to completion
// or failure on the calling thread, so chaining is a plain try/catch.
package kotlinx.coroutines.test

actual fun testResultChain(block: () -> TestResult, after: (Result<Unit>) -> TestResult): TestResult {
    try {
        block()
        after(Result.success(Unit))
    } catch (e: Throwable) {
        after(Result.failure(e))
    }
}
