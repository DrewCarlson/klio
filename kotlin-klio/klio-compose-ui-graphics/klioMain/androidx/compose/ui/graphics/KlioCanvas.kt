/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize

// The platform canvas handle. klio draws through the Skia shim by surface handle,
// so this is only a marker for Canvas's framework-canvas accessor.
actual class NativeCanvas

/**
 * The paint colour as packed 0xAARRGGBB with the paint alpha folded in. Reads the
 * colour's own channels (avoiding `toArgb`, whose colourspace conversion is a
 * deferred path); correct for sRGB colours, which is the common case.
 */
private fun Paint.argb(): Int {
    val c = color
    val a = ((c.alpha * alpha) * 255f + 0.5f).toInt().coerceIn(0, 255)
    val r = (c.red * 255f + 0.5f).toInt().coerceIn(0, 255)
    val g = (c.green * 255f + 0.5f).toInt().coerceIn(0, 255)
    val b = (c.blue * 255f + 0.5f).toInt().coerceIn(0, 255)
    return (a shl 24) or (r shl 16) or (g shl 8) or b
}

private fun Paint.styleCode(): Int = if (style == PaintingStyle.Stroke) 1 else 0

private fun Paint.capCode(): Int = when (strokeCap) {
    StrokeCap.Round -> 1
    StrokeCap.Square -> 2
    else -> 0
}

private fun Paint.joinCode(): Int = when (strokeJoin) {
    StrokeJoin.Round -> 1
    StrokeJoin.Bevel -> 2
    else -> 0
}

private fun Paint.aaCode(): Int = if (isAntiAlias) 1 else 0

private fun ClipOp.code(): Int = if (this == ClipOp.Difference) 0 else 1

/**
 * The klio [Canvas] actual: drives an SkCanvas on an offscreen surface (identified
 * by [handle]) through the Skia shim. Transforms and clips mutate the canvas
 * state; shapes and paths draw with the paint's fill/stroke geometry. Image,
 * point, and vertex draws need surfaces not yet vendored and throw pending.
 */
internal class KlioCanvas(private val handle: Long) : Canvas {
    override fun save() { __skia_c_save(handle) }

    override fun restore() { __skia_c_restore(handle) }

    // saveLayer's compositing (bounds + paint alpha/blend) is approximated by a
    // plain save for now; the transform/clip stack is preserved either way.
    override fun saveLayer(bounds: Rect, paint: Paint) { __skia_c_save(handle) }

    override fun translate(dx: Float, dy: Float) { __skia_c_translate(handle, dx, dy) }

    override fun scale(sx: Float, sy: Float) { __skia_c_scale(handle, sx, sy) }

    override fun rotate(degrees: Float) { __skia_c_rotate(handle, degrees) }

    override fun skew(sx: Float, sy: Float) { __skia_c_skew(handle, sx, sy) }

    // DrawScope composes its transforms through translate/scale/rotate; a raw
    // matrix concat is uncommon and left unapplied for now.
    override fun concat(matrix: Matrix) {}

    override fun clipRect(left: Float, top: Float, right: Float, bottom: Float, clipOp: ClipOp) {
        __skia_c_clip_rect(handle, left, top, right, bottom, clipOp.code())
    }

    override fun clipPath(path: Path, clipOp: ClipOp) {
        val t = (path as? KlioPath)?.serialize() ?: return
        __skia_c_clip_path(handle, t, clipOp.code())
    }

    override fun drawLine(p1: Offset, p2: Offset, paint: Paint) {
        __skia_c_draw_line(handle, p1.x, p1.y, p2.x, p2.y, paint.argb(), paint.strokeWidth, paint.capCode(), paint.aaCode())
    }

    override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
        __skia_c_draw_rect(handle, left, top, right, bottom, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawRoundRect(left: Float, top: Float, right: Float, bottom: Float, radiusX: Float, radiusY: Float, paint: Paint) {
        __skia_c_draw_rrect(handle, left, top, right, bottom, radiusX, radiusY, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawOval(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) {
        __skia_c_draw_oval(handle, left, top, right, bottom, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawCircle(center: Offset, radius: Float, paint: Paint) {
        __skia_c_draw_circle(handle, center.x, center.y, radius, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawArc(left: Float, top: Float, right: Float, bottom: Float, startAngle: Float, sweepAngle: Float, useCenter: Boolean, paint: Paint) {
        val oval = Rect(left, top, right, bottom)
        val p = Path()
        if (useCenter) {
            p.moveTo(oval.center.x, oval.center.y)
            p.arcTo(oval, startAngle, sweepAngle, forceMoveTo = false)
            p.close()
        } else {
            p.arcTo(oval, startAngle, sweepAngle, forceMoveTo = true)
        }
        drawPath(p, paint)
    }

    override fun drawPath(path: Path, paint: Paint) {
        val t = (path as? KlioPath)?.serialize() ?: return
        __skia_c_draw_path(handle, t, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawImage(image: ImageBitmap, topLeftOffset: Offset, paint: Paint): Unit =
        throw NotImplementedError("Canvas.drawImage requires ImageBitmap support")

    override fun drawImageRect(
        image: ImageBitmap,
        srcOffset: IntOffset,
        srcSize: IntSize,
        dstOffset: IntOffset,
        dstSize: IntSize,
        paint: Paint,
    ): Unit = throw NotImplementedError("Canvas.drawImageRect requires ImageBitmap support")

    override fun drawPoints(pointMode: PointMode, points: List<Offset>, paint: Paint): Unit =
        throw NotImplementedError("Canvas.drawPoints is not yet supported")

    override fun drawRawPoints(pointMode: PointMode, points: FloatArray, paint: Paint): Unit =
        throw NotImplementedError("Canvas.drawRawPoints is not yet supported")

    override fun drawVertices(vertices: Vertices, blendMode: BlendMode, paint: Paint): Unit =
        throw NotImplementedError("Canvas.drawVertices is not yet supported")

    override fun enableZ() {}

    override fun disableZ() {}
}

/** klio has no ImageBitmap-backed canvas yet (ImageBitmap construction is pending). */
internal actual fun ActualCanvas(image: ImageBitmap): Canvas =
    throw NotImplementedError("Canvas over an ImageBitmap is not yet supported")

/**
 * klio helper: create an offscreen [width] x [height] surface, draw [block] onto
 * a real [Canvas], and save it as a PNG at [path]. No-op (returns false) when no
 * Skia backend is available, so it stays headless-safe. The real
 * `graphics.drawscope.DrawScope` render path wraps this same Canvas.
 */
fun klioDrawToPng(width: Int, height: Int, path: String, block: Canvas.() -> Unit): Boolean {
    val handle = __skia_surf_new(width, height)
    if (handle == 0L) return false
    KlioCanvas(handle).block()
    val ok = __skia_surf_save_png(handle, path) != 0L
    __skia_surf_free(handle)
    return ok
}
