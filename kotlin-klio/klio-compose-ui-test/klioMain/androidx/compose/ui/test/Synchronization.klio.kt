/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The UI thread a test's scene runs on, as the desktop's event dispatch
// thread: a thread of its own, apart from the one the test body runs on, so
// a test that sets content from its body waits for the content to settle.
// Work reaches it through runOnUiThread, which waits for the work to finish
// and rethrows what it threw, as Swing's invokeAndWait does.

package androidx.compose.ui.test

import kotlin.concurrent.Volatile
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking

private val uiDispatcher by lazy { newSingleThreadContext("Compose UI test") }

@Volatile private var uiThreadHandle: klio.Thread? = null

private fun uiThread(): klio.Thread =
    uiThreadHandle ?: runBlocking(uiDispatcher) { klio.Thread.currentThread() }.also { uiThreadHandle = it }

/**
 * Runs the given action on the UI thread.
 *
 * This method is blocking until the action is complete.
 */
internal actual fun <T> runOnUiThread(action: () -> T): T =
    if (isOnUiThread()) action() else runBlocking(uiDispatcher) { action() }

/** Returns if the call is made on the UI thread. */
internal actual fun isOnUiThread(): Boolean = klio.Thread.currentThread() === uiThread()

/** Blocks the calling thread for [timeMillis] milliseconds. */
internal actual fun sleep(timeMillis: Long) {
    klio.Thread.sleep(timeMillis)
}
