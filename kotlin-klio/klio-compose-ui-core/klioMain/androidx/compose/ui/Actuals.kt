/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui

import androidx.compose.ui.node.ModifierNodeElement
import androidx.compose.ui.platform.InspectorInfo

// klioMain actuals for the ui engine's platform `expect`s (ui/Expect.kt). These
// are the desktop-headless implementations klio supplies in place of skikoMain.

internal actual fun areObjectsOfSameType(a: Any, b: Any): Boolean =
    a::class == b::class

internal actual fun classKeyForObject(a: Any): Any = a::class

// Reflective inspector population is a debug-tooling feature (layout inspector);
// klio has no reflective element walk, so this is a no-op — inspector info that
// a modifier declares explicitly is unaffected.
internal actual fun InspectorInfo.tryPopulateReflectively(element: ModifierNodeElement<*>) {}

// A monotonically increasing millisecond clock. klio exposes no wall clock, and
// the engine uses this only for throttling / event timing (positive deltas), so
// a counter advancing ~one frame per read is sufficient and deterministic.
private var timeMillisCounter: Long = 0L

internal actual fun currentTimeMillis(): Long {
    timeMillisCounter += 16L
    return timeMillisCounter
}

// Delayed work backs the rect-manager's throttled callback dispatch. A headless
// single-frame render does not need the deferred pass, so scheduling is a no-op
// returning a token that `removePost` can accept.
internal actual fun postDelayed(delayMillis: Long, block: () -> Unit): Any = Any()

internal actual fun removePost(token: Any?) {}
