/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics.layer

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.isSpecified
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.toSize

/**
 * The klio [GraphicsLayer] actual. klio draws every node directly into the
 * window's raster surface (see KlioOwnedLayer), and its GraphicsContext creates
 * no layers, so this class holds the layer's properties and outline but has no
 * display list to record into or composite: [record], [draw] and
 * [toImageBitmap] report that offscreen layers are not supported.
 */
actual class GraphicsLayer internal constructor() {
    actual var compositingStrategy: CompositingStrategy = CompositingStrategy.Auto
    actual var topLeft: IntOffset = IntOffset.Zero
    actual var size: IntSize = IntSize.Zero
        private set
    actual var pivotOffset: Offset = Offset.Unspecified
    actual var alpha: Float = 1f
    actual var scaleX: Float = 1f
    actual var scaleY: Float = 1f
    actual var translationX: Float = 0f
    actual var translationY: Float = 0f
    actual var shadowElevation: Float = 0f
    actual var ambientShadowColor: Color = Color.Black
    actual var spotShadowColor: Color = Color.Black
    actual var blendMode: BlendMode = BlendMode.SrcOver
    actual var colorFilter: ColorFilter? = null
    actual var rotationX: Float = 0f
    actual var rotationY: Float = 0f
    actual var rotationZ: Float = 0f
    actual var cameraDistance: Float = DefaultCameraDistance
    actual var clip: Boolean = false
    actual var renderEffect: RenderEffect? = null
    actual var isReleased: Boolean = false
        private set

    private var outlinePath: Path? = null
    private var outlineTopLeft: Offset = Offset.Zero
    private var outlineSize: Size = Size.Unspecified
    private var outlineCornerRadius: Float = 0f

    actual val outline: Outline
        get() {
            outlinePath?.let { return Outline.Generic(it) }
            val outlineSize = if (outlineSize.isSpecified) outlineSize else size.toSize()
            val rect =
                Rect(
                    outlineTopLeft.x,
                    outlineTopLeft.y,
                    outlineTopLeft.x + outlineSize.width,
                    outlineTopLeft.y + outlineSize.height,
                )
            return if (outlineCornerRadius > 0f) {
                Outline.Rounded(RoundRect(rect, CornerRadius(outlineCornerRadius)))
            } else {
                Outline.Rectangle(rect)
            }
        }

    actual fun setOutsets(left: Int, top: Int, right: Int, bottom: Int) {}

    actual fun setPathOutline(path: Path) {
        outlinePath = path
    }

    actual fun setRoundRectOutline(topLeft: Offset, size: Size, cornerRadius: Float) {
        outlinePath = null
        outlineTopLeft = topLeft
        outlineSize = size
        outlineCornerRadius = cornerRadius
    }

    actual fun setRectOutline(topLeft: Offset, size: Size) {
        setRoundRectOutline(topLeft, size, 0f)
    }

    actual fun record(
        density: Density,
        layoutDirection: LayoutDirection,
        size: IntSize,
        block: DrawScope.() -> Unit,
    ) {
        throw UnsupportedOperationException("klio: GraphicsLayer recording is not supported")
    }

    actual suspend fun toImageBitmap(): ImageBitmap =
        throw UnsupportedOperationException("klio: GraphicsLayer.toImageBitmap is not supported")

    internal actual fun draw(canvas: Canvas, parentLayer: GraphicsLayer?) {
        throw UnsupportedOperationException("klio: GraphicsLayer drawing is not supported")
    }
}
