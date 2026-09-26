// The actual of lifecycle-runtime commonTest's runLifecycleTest for klio,
// as the desktop test set's is: the block runs blocking on Dispatchers.Main,
// which klio's main dispatcher makes able to dispatch, as the expect asks.
// Composed into the lifecycle_runtime suite; the upstream test sources are
// never edited.

package androidx.lifecycle

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestResult

actual fun runLifecycleTest(block: suspend CoroutineScope.() -> Unit): TestResult =
    runBlocking(Dispatchers.Main, block)
