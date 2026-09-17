// klio-owned copy of upstream kotlinx-coroutines-test/native/src: the
// platform actuals klio adapts. `systemPropertyImpl` reads the process
// environment (dots mapped to underscores) so `runTest`'s default timeout
// is configurable per run (`kotlinx_coroutines_test_default_timeout=10s`).
package kotlinx.coroutines.test
import kotlinx.coroutines.*

public actual typealias TestResult = Unit

internal actual fun createTestResult(testProcedure: suspend CoroutineScope.() -> Unit) {
    runBlocking {
        testProcedure()
    }
}

internal actual fun systemPropertyImpl(name: String): String? =
    kotlinx.coroutines.__kxco_systemProperty(name)

internal actual fun dumpCoroutines() { }
