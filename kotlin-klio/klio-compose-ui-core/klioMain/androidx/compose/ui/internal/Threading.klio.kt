/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The calling thread's id, which a scene's frame recomposer compares to run
// work on the thread its frames run on.

package androidx.compose.ui.internal

internal fun __composeui_currentThreadId(): Long =
    error("intrinsic androidx.compose.ui.internal.__composeui_currentThreadId not installed")

internal actual fun getCurrentThreadId(): Long = __composeui_currentThreadId()
