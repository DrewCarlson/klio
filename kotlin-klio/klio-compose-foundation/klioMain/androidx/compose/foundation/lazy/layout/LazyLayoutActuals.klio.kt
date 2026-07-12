/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.lazy.layout

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember

// The stable fallback key for an item with no user-provided key: equal for
// equal indices across compositions (the skiko actual's shape).
private data class DefaultLazyKey(private val index: Int)

actual fun getDefaultLazyLayoutKey(index: Int): Any = DefaultLazyKey(index)

// klio runs single-threaded frame loops with no idle-time host callback, so
// prefetch requests execute immediately: the work a real scheduler would do
// between frames simply happens inline, keeping behavior deterministic.
private class KlioPrefetchScheduler : PrefetchScheduler {
    override fun schedulePrefetch(prefetchRequest: PrefetchRequest) {
        val scope =
            object : PrefetchRequestScope {
                // Report ample time so a request completes in one execution.
                override fun availableTimeNanos(): Long = 1_000_000_000L
            }
        var again = true
        var guard = 0
        while (again && guard < 1024) {
            again = with(prefetchRequest) { scope.execute() }
            guard++
        }
    }
}

@Composable
internal actual fun rememberDefaultPrefetchScheduler(): PrefetchScheduler {
    return remember { KlioPrefetchScheduler() }
}
