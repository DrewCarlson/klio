/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The scene context of skiko's ComposeSceneContext.skiko.kt that Popup and
// Dialog reach through rememberComposeSceneLayer: the scene a composition runs
// in, which makes the layers they draw above it. skiko's also carries the
// scene's PlatformContext; klio's host provides its platform services as
// composition locals instead, so the context here is the layer factory alone.
package androidx.compose.ui.scene

import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection

internal val LocalComposeSceneContext = staticCompositionLocalOf<ComposeSceneContext?> { null }

@Composable
internal fun CompositionLocal<ComposeSceneContext?>.requireCurrent(): ComposeSceneContext {
    return current ?: error("CompositionLocal LocalComposeSceneContext not provided")
}

@InternalComposeUiApi
interface ComposeSceneContext {
    fun createLayer(
        density: Density,
        layoutDirection: LayoutDirection,
        focusable: Boolean,
        consumePointerInputOutside: Boolean = focusable,
    ): ComposeSceneLayer {
        throw IllegalStateException()
    }
}
