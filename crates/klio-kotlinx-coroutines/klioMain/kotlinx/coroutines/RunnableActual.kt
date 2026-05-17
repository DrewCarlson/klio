// Platform `actual` for the curated upstream `Runnable.common.kt`
// `expect fun interface`. On klio there is no java.lang.Runnable; a
// runnable task is just a no-arg unit lambda, so the actual is the
// minimal SAM interface the cooperative dispatchers invoke directly.

package kotlinx.coroutines

actual fun interface Runnable {
    actual fun run()
}
