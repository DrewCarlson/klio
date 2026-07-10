/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.input.pointer

import androidx.compose.ui.InternalCoreApi

/**
 * klio actual: the processor consumes only the uptime and the per-pointer data
 * list; the window driver synthesizes these from the SDL/Cocoa event stream.
 */
@OptIn(InternalCoreApi::class)
internal actual class PointerInputEvent(
    actual val uptime: Long,
    actual val pointers: List<PointerInputEventData>,
)

/**
 * klio actual: changes keyed by pointer id, with active-hover derived from the
 * originating event's per-pointer data (the skiko semantics).
 */
@OptIn(InternalCoreApi::class)
internal actual class InternalPointerEvent actual constructor(
    actual val changes: androidx.collection.LongSparseArray<PointerInputChange>,
    private val pointerInputEvent: PointerInputEvent,
) {
    actual var suppressMovementConsumption: Boolean = false

    actual fun activeHoverEvent(pointerId: PointerId): Boolean {
        for (p in pointerInputEvent.pointers) {
            if (p.id == pointerId) return p.activeHover
        }
        return false
    }
}
