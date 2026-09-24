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
import androidx.compose.ui.geometry.isUnspecified
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.KlioCanvas
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.__skia_c_draw_picture
import androidx.compose.ui.graphics.__skia_c_save_layer
import androidx.compose.ui.graphics.__skia_c_set_color_filter
import androidx.compose.ui.graphics.__skia_picture_free
import androidx.compose.ui.graphics.__skia_rec_begin
import androidx.compose.ui.graphics.__skia_rec_end
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.draw
import androidx.compose.ui.graphics.skiaCode
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.toSize

/**
 * The klio [GraphicsLayer] actual, after skiko's SkiaGraphicsLayer. [record]
 * draws the block into a Skia picture and [draw] replays it: at [topLeft],
 * under the layer's pivoted transform, clipped to its outline when [clip] is
 * set, and through an offscreen layer when its alpha, blend mode, color filter,
 * render effect or compositing strategy asks for one. A layer is drawn again
 * without re-recording, so a transform or alpha change costs no draw pass.
 *
 * Headless (no Skia backend) the block still runs, so what it does besides
 * drawing happens, and there is no picture to draw.
 */
actual class GraphicsLayer internal constructor() {
    private val pictureDrawScope = CanvasDrawScope()

    /** What [record] last drew, as a shim picture handle; 0 before it or headless. */
    private var picture = 0L

    private var outsetLeft = 0
    private var outsetTop = 0
    private var outsetRight = 0
    private var outsetBottom = 0

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
    private var roundRectOutlineTopLeft: Offset = Offset.Zero
    private var roundRectOutlineSize: Size = Size.Unspecified
    private var roundRectCornerRadius: Float = 0f

    actual val outline: Outline
        get() {
            outlinePath?.let { return Outline.Generic(it) }
            val outlineSize = if (roundRectOutlineSize.isUnspecified) size.toSize() else roundRectOutlineSize
            val left = roundRectOutlineTopLeft.x
            val top = roundRectOutlineTopLeft.y
            val right = left + outlineSize.width
            val bottom = top + outlineSize.height
            return if (roundRectCornerRadius > 0f) {
                Outline.Rounded(RoundRect(left, top, right, bottom, CornerRadius(roundRectCornerRadius)))
            } else {
                Outline.Rectangle(Rect(left, top, right, bottom))
            }
        }

    actual fun setOutsets(left: Int, top: Int, right: Int, bottom: Int) {
        require(left >= 0 && top >= 0 && right >= 0 && bottom >= 0) {
            "Outsets cannot be negative! Left: $left, Top: $top, Right: $right, Bottom: $bottom"
        }
        outsetLeft = left
        outsetTop = top
        outsetRight = right
        outsetBottom = bottom
    }

    actual fun setPathOutline(path: Path) {
        outlinePath = path
        roundRectOutlineSize = Size.Unspecified
        roundRectOutlineTopLeft = Offset.Zero
        roundRectCornerRadius = 0f
    }

    actual fun setRoundRectOutline(topLeft: Offset, size: Size, cornerRadius: Float) {
        outlinePath = null
        roundRectOutlineTopLeft = topLeft
        roundRectOutlineSize = size
        roundRectCornerRadius = cornerRadius
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
        this.size = size
        val recording = __skia_rec_begin(size.width.toFloat(), size.height.toFloat())
        pictureDrawScope.draw(
            density = density,
            layoutDirection = layoutDirection,
            canvas = KlioCanvas(recording),
            size = size.toSize(),
            graphicsLayer = this,
            block = block,
        )
        val recorded = if (recording != 0L) __skia_rec_end(recording) else 0L
        if (picture != 0L) __skia_picture_free(picture)
        picture = recorded
    }

    actual suspend fun toImageBitmap(): ImageBitmap =
        ImageBitmap(size.width, size.height).apply { draw(Canvas(this), null) }

    internal actual fun draw(canvas: Canvas, parentLayer: GraphicsLayer?) {
        if (isReleased) return
        val handle = (canvas as? KlioCanvas)?.nativeHandle ?: return
        if (picture == 0L || handle == 0L) return
        val layer = requiresLayer()
        val outsets = outsetLeft > 0 || outsetTop > 0 || outsetRight > 0 || outsetBottom > 0
        // With outsets the offscreen layer is opened here, around the transformed
        // content, over the layer's bounds grown by them.
        if (layer && outsets) {
            saveLayer(
                handle,
                (topLeft.x - outsetLeft).toFloat(),
                (topLeft.y - outsetTop).toFloat(),
                (topLeft.x + size.width + outsetRight).toFloat(),
                (topLeft.y + size.height + outsetBottom).toFloat(),
            )
        }
        canvas.save()
        canvas.translate(topLeft.x.toFloat(), topLeft.y.toFloat())
        if (hasTransform()) canvas.concat(transform())
        if (clip) clipToOutline(canvas)
        if (layer && !outsets) saveLayer(handle, 0f, 0f, size.width.toFloat(), size.height.toFloat())
        __skia_c_draw_picture(handle, picture)
        if (layer && !outsets) canvas.restore()
        canvas.restore()
        if (layer && outsets) canvas.restore()
    }

    internal fun release() {
        if (isReleased) return
        isReleased = true
        if (picture != 0L) __skia_picture_free(picture)
        picture = 0L
    }

    /**
     * Whether drawing needs an offscreen layer, as skiko decides: alpha under a
     * strategy other than ModulateAlpha, a color filter, a blend mode other than
     * SrcOver, a render effect, or the Offscreen strategy. Under ModulateAlpha
     * skiko multiplies each recorded draw's alpha instead; klio's canvas has no
     * alpha multiplier, so there the alpha takes the layer too, which differs
     * only where the content's own draws overlap.
     */
    private fun requiresLayer(): Boolean =
        alpha < 1f ||
            colorFilter != null ||
            blendMode != BlendMode.SrcOver ||
            renderEffect != null ||
            compositingStrategy == CompositingStrategy.Offscreen

    private fun saveLayer(handle: Long, l: Float, t: Float, r: Float, b: Float) {
        val filter = colorFilter?.nativeColorFilter
        if (filter != null) __skia_c_set_color_filter(handle, filter.argb, filter.mode)
        val blur = renderEffect as? BlurEffect
        __skia_c_save_layer(
            handle, l, t, r, b, 1,
            alpha,
            blendMode.skiaCode(),
            blur?.klioBlurSigmaX ?: 0f,
            blur?.klioBlurSigmaY ?: 0f,
            blur?.klioBlurTileCode ?: 0,
        )
        if (filter != null) __skia_c_set_color_filter(handle, 0, -1)
    }

    private fun hasTransform(): Boolean =
        translationX != 0f || translationY != 0f || scaleX != 1f || scaleY != 1f ||
            rotationX != 0f || rotationY != 0f || rotationZ != 0f

    /** The layer's transform about its pivot, the size's center when unspecified. */
    private fun transform(): Matrix {
        val pivot = if (pivotOffset.isUnspecified) Offset(size.width / 2f, size.height / 2f) else pivotOffset
        return Matrix().apply {
            resetToPivotedTransform(
                pivotX = pivot.x,
                pivotY = pivot.y,
                translationX = translationX,
                translationY = translationY,
                rotationX = rotationX,
                rotationY = rotationY,
                rotationZ = rotationZ,
                scaleX = scaleX,
                scaleY = scaleY,
            )
        }
    }

    private fun clipToOutline(canvas: Canvas) {
        when (val o = outline) {
            is Outline.Rectangle -> canvas.clipRect(o.rect)
            is Outline.Rounded -> canvas.clipPath(Path().apply { addRoundRect(o.roundRect) })
            is Outline.Generic -> canvas.clipPath(o.path)
        }
    }
}
