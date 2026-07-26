// klio runs real worker threads: a synchronized block holds the lock
// object's monitor for the block's duration, exactly like the JVM actual.
package androidx.compose.ui.platform

internal actual class SynchronizedObject

internal actual inline fun makeSynchronizedObject(ref: Any?): SynchronizedObject = SynchronizedObject()

internal actual inline fun <R> synchronized(lock: SynchronizedObject, block: () -> R): R =
    kotlin.synchronized(lock, block)
