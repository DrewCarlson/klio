/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.gestures

import androidx.compose.animation.core.exponentialDecay
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEvent
import androidx.compose.ui.node.CompositionLocalConsumerModifierNode
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.util.fastFold

actual val LocalBringIntoViewSpec: ProvidableCompositionLocal<BringIntoViewSpec> =
    staticCompositionLocalOf {
        BringIntoViewSpec.DefaultBringIntoViewSpec
    }

// Desktop mouse-wheel scrolling: one wheel notch scrolls a fixed line height,
// scaled by density (the skiko actual's shape without platform config hooks).
private const val WheelScrollLinePx = 64f

private object KlioScrollConfig : ScrollConfig {
    override fun Density.calculateMouseWheelScroll(event: PointerEvent, bounds: IntSize): Offset {
        val delta = event.changes.fastFold(Offset.Zero) { acc, c -> acc + c.scrollDelta }
        return delta * -WheelScrollLinePx
    }
}

internal actual fun CompositionLocalConsumerModifierNode.platformScrollConfig(): ScrollConfig =
    KlioScrollConfig

internal actual fun platformScrollableDefaultFlingBehavior(): ScrollableDefaultFlingBehavior =
    DefaultFlingBehavior(exponentialDecay())

@Composable
internal actual fun rememberPlatformDefaultFlingBehavior(): FlingBehavior =
    remember { DefaultFlingBehavior(exponentialDecay()) }
