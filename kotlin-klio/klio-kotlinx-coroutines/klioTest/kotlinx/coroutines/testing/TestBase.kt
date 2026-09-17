/*
 * klio-authored platform actuals for the kotlinx-coroutines test
 * infrastructure (`test-utils`). KLIO runs the test tree on real worker
 * threads with a runBlocking-backed event loop per test, so `runTest` drives
 * the block through `runBlocking` and `TestResult` is `Unit`. None of the
 * optional `No*` skip annotations get an actual: klio skips nothing for
 * platform reasons — a test that cannot pass is a defect to fix, not to hide.
 */

package kotlinx.coroutines.testing

import kotlin.test.*
import kotlinx.coroutines.*

actual val VERBOSE = false

actual val isStressTest: Boolean = false
actual val stressTestMultiplier: Int = 1
actual val stressTestMultiplierSqrt: Int = 1

actual typealias TestResult = Unit

internal actual fun lastResortReportException(error: Throwable) {
    println(error)
}

actual open class TestBase actual constructor() : OrderedExecutionTestBase(), ErrorCatching by ErrorCatching.Impl() {
    actual fun println(message: Any?) {
        kotlin.io.println(message)
    }

    actual fun runTest(
        expected: ((Throwable) -> Boolean)?,
        unhandled: List<(Throwable) -> Boolean>,
        block: suspend CoroutineScope.() -> Unit
    ) {
        var exCount = 0
        var ex: Throwable? = null
        try {
            runBlocking(block = block, context = CoroutineExceptionHandler { _, e ->
                if (e is CancellationException) return@CoroutineExceptionHandler // are ignored
                exCount++
                when {
                    exCount > unhandled.size ->
                        error("Too many unhandled exceptions $exCount, expected ${unhandled.size}, got: $e", e)
                    !unhandled[exCount - 1](e) ->
                        error("Unhandled exception was unexpected: $e", e)
                }
            })
        } catch (e: Throwable) {
            ex = e
            if (expected != null) {
                if (!expected(e))
                    error("Unexpected exception: $e", e)
            } else
                throw e
        } finally {
            if (ex == null && expected != null) error("Exception was expected but none produced")
        }
        if (exCount < unhandled.size)
            error("Too few unhandled exceptions $exCount, expected ${unhandled.size}")
    }
}

actual val isNative = false

actual val isBoundByJsTestTimeout = false

actual val isJavaAndWindows: Boolean get() = false

actual val usesSharedEventLoop: Boolean = false
