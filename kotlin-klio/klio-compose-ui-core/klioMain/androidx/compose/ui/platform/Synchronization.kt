// klio is single-threaded: a synchronized block just runs its body.
package androidx.compose.ui.platform

internal actual class SynchronizedObject

internal actual inline fun makeSynchronizedObject(ref: Any?): SynchronizedObject = SynchronizedObject()

internal actual inline fun <R> synchronized(lock: SynchronizedObject, block: () -> R): R = block()
