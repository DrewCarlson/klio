/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The graphics layers' native nodes: skiko's RenderNode and RenderNodeContext,
// compiled into the Skia shim (src/compose_ui/skiko), behind handles. These
// classes carry skiko's org.jetbrains.skiko.node API where GraphicsLayer uses
// it. Headless every handle is 0 and every call does nothing.
package androidx.compose.ui.graphics.layer

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.KlioPath
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.RenderEffect
import androidx.compose.ui.graphics.skiaCode

internal fun __skia_rn_context_new(measureDrawBounds: Int): Long = error("intrinsic __skia_rn_context_new not installed")
internal fun __skia_rn_context_free(context: Long): Long = error("intrinsic __skia_rn_context_free not installed")
internal fun __skia_rn_context_set_lighting(
    context: Long, centerX: Float, centerY: Float, centerZ: Float, radius: Float,
    ambientShadowAlpha: Float, spotShadowAlpha: Float,
): Long = error("intrinsic __skia_rn_context_set_lighting not installed")
internal fun __skia_rn_new(context: Long): Long = error("intrinsic __skia_rn_new not installed")
internal fun __skia_rn_free(node: Long): Long = error("intrinsic __skia_rn_free not installed")
// which: 0 alpha, 1 scaleX, 2 scaleY, 3 translationX, 4 translationY,
// 5 shadowElevation, 6 rotationX, 7 rotationY, 8 rotationZ, 9 cameraDistance.
internal fun __skia_rn_set_float(node: Long, which: Int, value: Float): Long = error("intrinsic __skia_rn_set_float not installed")
// which: 0 ambient shadow color, 1 spot shadow color (ARGB).
internal fun __skia_rn_set_color(node: Long, which: Int, argb: Int): Long = error("intrinsic __skia_rn_set_color not installed")
internal fun __skia_rn_set_bounds(node: Long, l: Float, t: Float, r: Float, b: Float): Long = error("intrinsic __skia_rn_set_bounds not installed")
internal fun __skia_rn_set_pivot(node: Long, x: Float, y: Float): Long = error("intrinsic __skia_rn_set_pivot not installed")
internal fun __skia_rn_set_clip(node: Long, clip: Int): Long = error("intrinsic __skia_rn_set_clip not installed")
// kind: 0 none, 1 rect, 2 rounded rect with the radii (x, y) of the top-left,
// top-right, bottom-right and bottom-left corners, 3 the serialized path.
internal fun __skia_rn_set_outline(
    node: Long, kind: Int, l: Float, t: Float, r: Float, b: Float,
    tlx: Float, tly: Float, trx: Float, try_: Float, brx: Float, bry: Float, blx: Float, bly: Float,
    path: String?,
): Long = error("intrinsic __skia_rn_set_outline not installed")
// has 0 clears the paint; otherwise alpha, blend mode (skiaCode), and the color
// filter and image filter specs ("" for none).
internal fun __skia_rn_set_layer_paint(
    node: Long, has: Int, alpha: Float, blendMode: Int, colorFilter: String, imageFilter: String,
): Long = error("intrinsic __skia_rn_set_layer_paint not installed")
internal fun __skia_rn_begin_recording(node: Long): Long = error("intrinsic __skia_rn_begin_recording not installed")
internal fun __skia_rn_end_recording(node: Long, recording: Long): Long = error("intrinsic __skia_rn_end_recording not installed")
internal fun __skia_rn_draw_into(node: Long, canvas: Long): Long = error("intrinsic __skia_rn_draw_into not installed")

/** skiko's RenderNodeContext: what a scene's layers share, their light. */
internal class KlioRenderNodeContext(measureDrawBounds: Boolean) {
    internal var handle: Long = __skia_rn_context_new(if (measureDrawBounds) 1 else 0)
        private set

    fun setLightingInfo(
        centerX: Float,
        centerY: Float,
        centerZ: Float,
        radius: Float,
        ambientShadowAlpha: Float,
        spotShadowAlpha: Float,
    ) {
        __skia_rn_context_set_lighting(handle, centerX, centerY, centerZ, radius, ambientShadowAlpha, spotShadowAlpha)
    }

    fun close() {
        __skia_rn_context_free(handle)
        handle = 0L
    }
}

/** skiko's RenderNode, the drawable one GraphicsLayer records into and draws. */
internal class KlioRenderNode(context: KlioRenderNodeContext) {
    private var handle: Long = __skia_rn_new(context.handle)

    fun setBounds(left: Float, top: Float, right: Float, bottom: Float) {
        __skia_rn_set_bounds(handle, left, top, right, bottom)
    }

    /** An unspecified pivot is the bounds' center. */
    fun setPivot(pivot: Offset) {
        __skia_rn_set_pivot(handle, pivot.x, pivot.y)
    }

    var alpha: Float = 1f
        set(value) { field = value; __skia_rn_set_float(handle, 0, value) }
    var scaleX: Float = 1f
        set(value) { field = value; __skia_rn_set_float(handle, 1, value) }
    var scaleY: Float = 1f
        set(value) { field = value; __skia_rn_set_float(handle, 2, value) }
    var translationX: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 3, value) }
    var translationY: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 4, value) }
    var shadowElevation: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 5, value) }
    var rotationX: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 6, value) }
    var rotationY: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 7, value) }
    var rotationZ: Float = 0f
        set(value) { field = value; __skia_rn_set_float(handle, 8, value) }
    var cameraDistance: Float = DefaultCameraDistance
        set(value) { field = value; __skia_rn_set_float(handle, 9, value) }
    var ambientShadowColor: Int = 0xFF000000.toInt()
        set(value) { field = value; __skia_rn_set_color(handle, 0, value) }
    var spotShadowColor: Int = 0xFF000000.toInt()
        set(value) { field = value; __skia_rn_set_color(handle, 1, value) }
    var clip: Boolean = false
        set(value) { field = value; __skia_rn_set_clip(handle, if (value) 1 else 0) }

    /** The outline the node clips to and casts its shadow from; null for none. */
    fun setOutline(outline: Outline?) {
        when (outline) {
            null -> __skia_rn_set_outline(handle, 0, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, null)
            is Outline.Rectangle -> with(outline.rect) {
                __skia_rn_set_outline(handle, 1, left, top, right, bottom, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, null)
            }
            is Outline.Rounded -> with(outline.roundRect) {
                __skia_rn_set_outline(
                    handle, 2, left, top, right, bottom,
                    topLeftCornerRadius.x, topLeftCornerRadius.y,
                    topRightCornerRadius.x, topRightCornerRadius.y,
                    bottomRightCornerRadius.x, bottomRightCornerRadius.y,
                    bottomLeftCornerRadius.x, bottomLeftCornerRadius.y,
                    null,
                )
            }
            is Outline.Generic -> {
                val text = (outline.path as? KlioPath)?.serialize() ?: ""
                __skia_rn_set_outline(handle, 3, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, text)
            }
        }
    }

    /**
     * The paint the node's content composites through, as skiko's layer paint:
     * the alpha, blend mode, color filter and render effect, or none.
     */
    fun setLayerPaint(
        present: Boolean,
        alpha: Float = 1f,
        blendMode: BlendMode = BlendMode.SrcOver,
        colorFilter: ColorFilter? = null,
        renderEffect: RenderEffect? = null,
    ) {
        if (!present) {
            __skia_rn_set_layer_paint(handle, 0, 1f, 3, "", "")
            return
        }
        __skia_rn_set_layer_paint(
            handle, 1, alpha, blendMode.skiaCode(),
            colorFilter?.nativeColorFilter?.spec ?: "", renderEffect?.klioImageFilter ?: "",
        )
    }

    /** A handle that draws like a surface's into the node's content; 0 headless. */
    fun beginRecording(): Long = __skia_rn_begin_recording(handle)

    fun endRecording(recording: Long) {
        __skia_rn_end_recording(handle, recording)
    }

    /** Draw the node, by reference, onto the canvas surface [canvasHandle]. */
    fun drawInto(canvasHandle: Long) {
        __skia_rn_draw_into(handle, canvasHandle)
    }

    fun close() {
        __skia_rn_free(handle)
        handle = 0L
    }
}
