// Actuals for the platform `synchronized` expect consumed by AwaiterQueue (the
// frame-clock awaiter store). Backed by klio's kotlinx.atomicfu locks, which the
// interpreter maps onto its monitor primitives.
package androidx.compose.runtime.platform

import kotlinx.atomicfu.locks.SynchronizedObject as AtomicfuSynchronizedObject

internal actual typealias SynchronizedObject = AtomicfuSynchronizedObject

internal actual inline fun makeSynchronizedObject(ref: Any?): SynchronizedObject = SynchronizedObject()

internal actual inline fun <R> synchronized(lock: SynchronizedObject, block: () -> R): R =
    kotlinx.atomicfu.locks.synchronized(lock, block)
