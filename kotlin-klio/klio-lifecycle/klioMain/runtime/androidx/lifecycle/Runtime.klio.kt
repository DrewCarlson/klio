// lifecycle-runtime's MainDispatcherChecker on klio: the desktop's, over
// klio.Thread in place of java.lang.Thread. The main dispatcher's thread is
// found by running on Dispatchers.Main.immediate and asked again when the
// calling thread differs.
package androidx.lifecycle

import kotlin.concurrent.Volatile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking

internal object MainDispatcherChecker {
    private var isMainDispatcherAvailable: Boolean = true
    @Volatile private var mainDispatcherThread: klio.Thread? = null

    private fun updateMainDispatcherThread() {
        try {
            runBlocking(Dispatchers.Main.immediate) {
                mainDispatcherThread = klio.Thread.currentThread()
            }
        } catch (_: IllegalStateException) {
            isMainDispatcherAvailable = false
        }
    }

    fun isMainDispatcherThread(): Boolean {
        if (!isMainDispatcherAvailable) return true
        val currentThread = klio.Thread.currentThread()
        if (currentThread === mainDispatcherThread) return true
        updateMainDispatcherThread()
        return !isMainDispatcherAvailable || currentThread === mainDispatcherThread
    }
}
