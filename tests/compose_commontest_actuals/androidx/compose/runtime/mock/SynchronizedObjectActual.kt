package androidx.compose.runtime.mock

internal actual class SynchronizedObject actual constructor()

internal actual inline fun <T> synchronizedImpl(
    lock: SynchronizedObject,
    crossinline action: () -> T,
): T = kotlin.synchronized(lock) { action() }
