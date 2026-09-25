/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.KlioRenderNode
import androidx.compose.ui.graphics.layer.KlioRenderNodeContext

/**
 * skiko's SkiaGraphicsContext (SkiaGraphicsContext.skiko.kt) over klio's
 * RenderNode binding: each layer it creates records into a RenderNode of this
 * context, and every layer of the context is lit by the light
 * [setLightingInfo] places, as the scene places it from its size.
 */
@InternalComposeUiApi
class SkiaGraphicsContext(
    measureDrawBounds: Boolean = false,
) : GraphicsContext {
    private val renderNodeContext = KlioRenderNodeContext(
        measureDrawBounds = measureDrawBounds,
    )
    private var isClosed = false

    // Temporary workaround to disable state tracking workaround inside old internal layers
    var activeGraphicsLayersCount = 0
        private set

    fun dispose() {
        require(!isClosed) { "GraphicsContext is already closed" }
        isClosed = true
        renderNodeContext.close()
    }

    fun setLightingInfo(
        centerX: Float = Float.MIN_VALUE,
        centerY: Float = Float.MIN_VALUE,
        centerZ: Float = Float.MIN_VALUE,
        radius: Float = 0f,
        ambientShadowAlpha: Float = 0f,
        spotShadowAlpha: Float = 0f
    ) {
        require(!isClosed) { "GraphicsContext is already closed" }
        renderNodeContext.setLightingInfo(
            centerX,
            centerY,
            centerZ,
            radius,
            ambientShadowAlpha,
            spotShadowAlpha
        )
    }

    override fun createGraphicsLayer(): GraphicsLayer {
        require(!isClosed) { "GraphicsContext is already closed" }
        activeGraphicsLayersCount++
        return GraphicsLayer(
            renderNode = KlioRenderNode(renderNodeContext)
        )
    }

    override fun releaseGraphicsLayer(layer: GraphicsLayer) {
        if (!layer.isReleased) {
            activeGraphicsLayersCount--
        }
        layer.release()
    }
}
