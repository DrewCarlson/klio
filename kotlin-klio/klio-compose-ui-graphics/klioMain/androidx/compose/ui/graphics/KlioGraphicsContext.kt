/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.graphics.layer.GraphicsLayer

/**
 * The klio host's [GraphicsContext], as skiko's SkiaGraphicsContext: each layer
 * it creates records into a Skia picture (see [GraphicsLayer]), and releasing
 * one frees its picture. Its shadow context is the interface's own.
 */
@InternalComposeUiApi
class KlioGraphicsContext : GraphicsContext {
    override fun createGraphicsLayer(): GraphicsLayer = GraphicsLayer()

    override fun releaseGraphicsLayer(layer: GraphicsLayer) {
        layer.release()
    }
}
