/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.input.pointer

import androidx.collection.LongSparseArray
import androidx.compose.ui.InternalCoreApi

/**
 * klio actual, mirroring the skiko shape: the platform PointerEvent actual
 * reads the event type, button, and modifier state off the internal event,
 * so the synthesized stream carries them (the window driver fills Press/
 * Release/Move; buttons and modifiers default to none).
 */
@OptIn(InternalCoreApi::class)
internal actual data class PointerInputEvent(
    val eventType: PointerEventType,
    actual val uptime: Long,
    actual val pointers: List<PointerInputEventData>,
    val buttons: PointerButtons = PointerButtons(0),
    val keyboardModifiers: PointerKeyboardModifiers = PointerKeyboardModifiers(0),
    val nativeEvent: Any? = null,
    val button: PointerButton? = null,
)

@OptIn(InternalCoreApi::class)
internal actual class InternalPointerEvent(
    val type: PointerEventType,
    actual val changes: LongSparseArray<PointerInputChange>,
    val buttons: PointerButtons,
    val keyboardModifiers: PointerKeyboardModifiers,
    val nativeEvent: Any?,
    val button: PointerButton?,
) {
    actual constructor(
        changes: LongSparseArray<PointerInputChange>,
        pointerInputEvent: PointerInputEvent,
    ) : this(
        pointerInputEvent.eventType,
        changes,
        pointerInputEvent.buttons,
        pointerInputEvent.keyboardModifiers,
        pointerInputEvent.nativeEvent,
        pointerInputEvent.button,
    )

    actual var suppressMovementConsumption: Boolean = false

    actual fun activeHoverEvent(pointerId: PointerId): Boolean =
        changes[pointerId.value]?.type == PointerType.Mouse
}
