/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// lifecycle-runtime's MainDispatcherChecker and WeakReference on klio. The
// checker is the desktop's, over klio.Thread in place of java.lang.Thread: the
// main dispatcher's thread is found by running on Dispatchers.Main.immediate
// and asked again when the calling thread differs. The collector has no weak
// references, so the reference is strong, as the other klio packs' are.
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

internal actual class WeakReference<T : Any> actual constructor(reference: T) {
    private val referent: T = reference

    actual fun get(): T? = referent
}
