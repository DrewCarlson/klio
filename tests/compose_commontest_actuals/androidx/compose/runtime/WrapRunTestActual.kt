// klio actual for the upstream test-utils `wrapRunTest` expect. On klio,
// `createTestResult` drives the test to completion synchronously through
// `runBlocking`, so the produced TestResult (= Unit) is already complete
// and `awaitCompletion` has nothing left to await.
package androidx.compose.runtime

import kotlinx.coroutines.test.TestResult

actual fun wrapRunTest(test: suspend WrapRunTestScope.() -> Unit): TestResult =
    kotlinx.coroutines.test.runTest {
        val scope = object : WrapRunTestScope {
            override suspend fun TestResult.awaitCompletion() {}
        }
        scope.test()
    }
