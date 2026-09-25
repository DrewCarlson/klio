/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection

// The platform canvas handle. klio draws through the Skia shim by surface handle,
// so this is only a marker for Canvas's framework-canvas accessor.
actual class NativeCanvas

/**
 * A paint of another implementation's colour as packed 0xAARRGGBB with its
 * alpha, times [alphaMultiplier], folded in. Reads the colour's own channels;
 * correct for sRGB colours.
 */
private fun Paint.foreignArgb(alphaMultiplier: Float): Int {
    val c = color
    val a = ((c.alpha * alpha * alphaMultiplier) * 255f + 0.5f).toInt().coerceIn(0, 255)
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

// The join the skia paint draws with, which for klio's paint is its skia
// state's, not the Compose property's default.
private fun Paint.joinCode(): Int = when (if (this is KlioPaint) skiaStrokeJoin else strokeJoin) {
    StrokeJoin.Round -> 1
    StrokeJoin.Bevel -> 2
    else -> 0
}

private fun Paint.aaCode(): Int = if (isAntiAlias) 1 else 0

private fun ClipOp.code(): Int = if (this == ClipOp.Difference) 0 else 1

// How an image samples, as skiko's canvas maps a paint's filter quality:
// 0 nearest, 1 linear, 2 linear with the nearest mipmap, 3 cubic (1/3, 1/3).
private fun FilterQuality.samplingCode(): Int = when (this) {
    FilterQuality.Low -> 1
    FilterQuality.Medium -> 2
    FilterQuality.High -> 3
    else -> 0
}

/**
 * The klio [Canvas] actual: drives an SkCanvas on an offscreen surface (identified
 * by [handle]) through the Skia shim. Transforms and clips mutate the canvas
 * state; shapes, paths, points and images draw with the paint's geometry, color,
 * shader, filters and blend mode. Vertex draws throw pending.
 */
internal class KlioCanvas(private val handle: Long) : Canvas {
    // The surface handle, exposed within the pack so the ui-text Paragraph engine
    // can draw glyph runs onto this exact canvas (same transform/clip state).
    internal val nativeHandle: Long get() = handle

    /**
     * What every paint's alpha is multiplied by, as skiko's canvas does: a
     * layer recorded under the ModulateAlpha strategy draws its content with
     * the layer's alpha here instead of through an offscreen layer.
     */
    internal var alphaMultiplier: Float = 1f
        set(value) {
            field = value.coerceIn(0f, 1f)
        }

    /**
     * Folds the canvas's alpha multiplier into [paint]'s color, once per draw,
     * as skiko's canvas does before it hands the skia paint to a draw.
     */
    private fun applyAlphaMultiplier(paint: Paint) {
        if (paint is KlioPaint) paint.alphaMultiplier = alphaMultiplier
    }

    /** The color the draw uses, after [applyAlphaMultiplier]. */
    private fun Paint.argb(): Int = if (this is KlioPaint) skiaColor else foreignArgb(alphaMultiplier)

    /** The alpha an image or a layer composites with, after [applyAlphaMultiplier]. */
    private fun Paint.drawAlpha(): Float =
        if (this is KlioPaint) Color(skiaColor).alpha else color.alpha * alpha * alphaMultiplier

    // A brush sets paint.shader; arm it on the shim for the next draw (the
    // shader defines the pixels, overriding the flat colour) and clear it after
    // so a later solid draw isn't tinted.
    private fun beginShader(paint: Paint): Boolean {
        val spec = paint.shader?.klioSpec ?: ""
        if (spec.isEmpty()) return false
        __skia_c_set_shader(handle, spec)
        return true
    }

    private fun endShader(active: Boolean) {
        if (active) __skia_c_set_shader(handle, "")
    }

    // A shadow's paint carries a blur; arm it on the shim for the next draw and
    // clear it after, so a later plain draw stays sharp.
    private fun beginBlur(paint: Paint): Boolean {
        val sigma = (paint as? KlioPaint)?.blurFilter?.sigma ?: 0f
        if (sigma <= 0f) return false
        __skia_c_set_blur(handle, sigma)
        return true
    }

    private fun endBlur(active: Boolean) {
        if (active) __skia_c_set_blur(handle, 0f)
    }

    // A paint's color filter (a tint, a color matrix, a lighting filter) and
    // path effect (dashes, rounded corners, stamps); armed and cleared around
    // the draw the same way.
    private fun beginColorFilter(paint: Paint): Boolean {
        val f = paint.colorFilter?.nativeColorFilter ?: return false
        __skia_c_set_color_filter(handle, f.spec)
        return true
    }

    private fun endColorFilter(active: Boolean) {
        if (active) __skia_c_set_color_filter(handle, "")
    }

    private fun beginPathEffect(paint: Paint): Boolean {
        val effect = paint.pathEffect as? KlioPathEffect ?: return false
        __skia_c_set_path_effect(handle, effect.spec)
        return true
    }

    private fun endPathEffect(active: Boolean) {
        if (active) __skia_c_set_path_effect(handle, "")
    }

    // A paint's blend mode (BlendMode.Clear, a SrcIn tint mask, ...) and, for an
    // image, the alpha it composites with (a shape's is folded into its color).
    // A paint's blend mode (BlendMode.Clear, a SrcIn tint mask, ...), for an
    // image the alpha it composites with (a shape's is folded into its color),
    // and the stroke miter limit.
    private fun beginPaintState(paint: Paint, image: Boolean): Boolean {
        val alpha = if (image) paint.drawAlpha() else 1f
        val miter = if (paint is KlioPaint) paint.skiaStrokeMiter else paint.strokeMiterLimit
        if (paint.blendMode == BlendMode.SrcOver && alpha == 1f && miter == 4f) return false
        __skia_c_set_paint_state(handle, paint.blendMode.skiaCode(), alpha, miter)
        return true
    }

    private fun endPaintState(active: Boolean) {
        if (active) __skia_c_set_paint_state(handle, -1, 1f, 4f)
    }

    /**
     * Arms every effect of [paint] for one shape draw, runs it, and clears them.
     * [apply] folds in the alpha multiplier first; a draw of many shapes with
     * one paint folds it in once, before the first.
     */
    private inline fun withPaint(paint: Paint, apply: Boolean = true, draw: () -> Unit) {
        if (apply) applyAlphaMultiplier(paint)
        val sh = beginShader(paint)
        val bl = beginBlur(paint)
        val cf = beginColorFilter(paint)
        val pe = beginPathEffect(paint)
        val ps = beginPaintState(paint, image = false)
        draw()
        endPaintState(ps)
        endPathEffect(pe)
        endColorFilter(cf)
        endBlur(bl)
        endShader(sh)
    }

    override fun save() { __skia_c_save(handle) }

    override fun restore() { __skia_c_restore(handle) }

    // An offscreen layer over the bounds, composited back at the matching
    // restore through the paint's alpha, blend mode and color filter.
    override fun saveLayer(bounds: Rect, paint: Paint) {
        applyAlphaMultiplier(paint)
        val cf = beginColorFilter(paint)
        __skia_c_save_layer(
            handle, bounds.left, bounds.top, bounds.right, bounds.bottom, 1,
            paint.drawAlpha(), paint.blendMode.skiaCode(), "",
        )
        endColorFilter(cf)
    }

    override fun translate(dx: Float, dy: Float) { __skia_c_translate(handle, dx, dy) }

    override fun scale(sx: Float, sy: Float) { __skia_c_scale(handle, sx, sy) }

    override fun rotate(degrees: Float) { __skia_c_rotate(handle, degrees) }

    override fun skew(sx: Float, sy: Float) { __skia_c_skew(handle, sx, sy) }

    // Concat the whole 4x4 matrix onto the canvas, perspective included, as
    // skiko's canvas concats its Matrix44; an identity matrix is skipped.
    override fun concat(matrix: Matrix) {
        if (matrix.isIdentity()) return
        val v = matrix.values
        __skia_c_concat44(
            handle,
            v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7],
            v[8], v[9], v[10], v[11], v[12], v[13], v[14], v[15],
        )
    }

    override fun clipRect(left: Float, top: Float, right: Float, bottom: Float, clipOp: ClipOp) {
        __skia_c_clip_rect(handle, left, top, right, bottom, clipOp.code())
    }

    override fun clipPath(path: Path, clipOp: ClipOp) {
        val t = (path as? KlioPath)?.serialize() ?: return
        __skia_c_clip_path(handle, t, clipOp.code())
    }

    override fun drawLine(p1: Offset, p2: Offset, paint: Paint) = withPaint(paint) {
        __skia_c_draw_line(handle, p1.x, p1.y, p2.x, p2.y, paint.argb(), paint.strokeWidth, paint.capCode(), paint.aaCode())
    }

    override fun drawRect(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) = withPaint(paint) {
        __skia_c_draw_rect(handle, left, top, right, bottom, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawRoundRect(left: Float, top: Float, right: Float, bottom: Float, radiusX: Float, radiusY: Float, paint: Paint) = withPaint(paint) {
        __skia_c_draw_rrect(handle, left, top, right, bottom, radiusX, radiusY, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawOval(left: Float, top: Float, right: Float, bottom: Float, paint: Paint) = withPaint(paint) {
        __skia_c_draw_oval(handle, left, top, right, bottom, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
    }

    override fun drawCircle(center: Offset, radius: Float, paint: Paint) = withPaint(paint) {
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
        withPaint(paint) {
            __skia_c_draw_path(handle, t, paint.argb(), paint.styleCode(), paint.strokeWidth, paint.capCode(), paint.joinCode(), paint.aaCode())
        }
    }

    override fun drawImage(image: ImageBitmap, topLeftOffset: Offset, paint: Paint) {
        val src = image.klioSurfaceHandle()
        if (src == 0L) return
        applyAlphaMultiplier(paint)
        val cf = beginColorFilter(paint)
        val ps = beginPaintState(paint, image = true)
        __skia_c_draw_surface(handle, src, topLeftOffset.x, topLeftOffset.y, paint.filterQuality.samplingCode())
        endPaintState(ps)
        endColorFilter(cf)
    }

    override fun drawImageRect(
        image: ImageBitmap,
        srcOffset: IntOffset,
        srcSize: IntSize,
        dstOffset: IntOffset,
        dstSize: IntSize,
        paint: Paint,
    ) {
        val src = image.klioSurfaceHandle()
        if (src == 0L) return
        applyAlphaMultiplier(paint)
        val cf = beginColorFilter(paint)
        val ps = beginPaintState(paint, image = true)
        __skia_c_draw_surface_rect(
            handle,
            src,
            srcOffset.x.toFloat(),
            srcOffset.y.toFloat(),
            (srcOffset.x + srcSize.width).toFloat(),
            (srcOffset.y + srcSize.height).toFloat(),
            dstOffset.x.toFloat(),
            dstOffset.y.toFloat(),
            (dstOffset.x + dstSize.width).toFloat(),
            (dstOffset.y + dstSize.height).toFloat(),
            paint.filterQuality.samplingCode(),
        )
        endPaintState(ps)
        endColorFilter(cf)
    }

    override fun drawPoints(pointMode: PointMode, points: List<Offset>, paint: Paint) {
        when (pointMode) {
            // A line between each pair of points; an odd last point is ignored.
            PointMode.Lines -> drawLines(points, paint, 2)
            // A line between each adjacent pair.
            PointMode.Polygon -> drawLines(points, paint, 1)
            // A dot at each point.
            else -> {
                applyAlphaMultiplier(paint)
                for (p in points) drawPoint(p.x, p.y, paint)
            }
        }
    }

    private fun drawLines(points: List<Offset>, paint: Paint, stepBy: Int) {
        if (points.size < 2) return
        applyAlphaMultiplier(paint)
        var i = 0
        while (i < points.size - 1) {
            val p1 = points[i]
            val p2 = points[i + 1]
            drawSegment(p1.x, p1.y, p2.x, p2.y, paint)
            i += stepBy
        }
    }

    // One segment or dot of a many-shape draw, whose alpha multiplier is folded in.
    private fun drawSegment(x1: Float, y1: Float, x2: Float, y2: Float, paint: Paint) = withPaint(paint, apply = false) {
        __skia_c_draw_line(handle, x1, y1, x2, y2, paint.argb(), paint.strokeWidth, paint.capCode(), paint.aaCode())
    }

    private fun drawPoint(x: Float, y: Float, paint: Paint) = withPaint(paint, apply = false) {
        __skia_c_draw_point(handle, x, y, paint.argb(), paint.strokeWidth, paint.capCode(), paint.aaCode())
    }

    /** @throws IllegalArgumentException if [points] holds an odd number of values */
    override fun drawRawPoints(pointMode: PointMode, points: FloatArray, paint: Paint) {
        if (points.size % 2 != 0) {
            throw IllegalArgumentException("points must have an even number of values")
        }
        when (pointMode) {
            PointMode.Lines -> drawRawLines(points, paint, 2)
            PointMode.Polygon -> drawRawLines(points, paint, 1)
            else -> {
                applyAlphaMultiplier(paint)
                var i = 0
                while (i < points.size - 1) {
                    drawPoint(points[i], points[i + 1], paint)
                    i += 2
                }
            }
        }
    }

    // The values are x, y pairs; a line joins pair i to pair i + 1, stepping by
    // stepBy pairs.
    private fun drawRawLines(points: FloatArray, paint: Paint, stepBy: Int) {
        if (points.size < 4 || points.size % 2 != 0) return
        applyAlphaMultiplier(paint)
        var i = 0
        while (i < points.size - 3) {
            drawSegment(points[i], points[i + 1], points[i + 2], points[i + 3], paint)
            i += stepBy * 2
        }
    }

    // The vertices' colors blend with the paint's shader by blendMode, as
    // skiko's canvas draws them.
    override fun drawVertices(vertices: Vertices, blendMode: BlendMode, paint: Paint) {
        val mode = when (vertices.vertexMode) {
            VertexMode.TriangleStrip -> 1
            VertexMode.TriangleFan -> 2
            else -> 0
        }
        val colors = vertices.colors.joinToString(" ") { (it.toLong() and 0xFFFFFFFFL).toString() }
        val indices = vertices.indices.joinToString(" ") { (it.toInt() and 0xFFFF).toString() }
        withPaint(paint) {
            __skia_c_draw_vertices(
                handle, mode,
                vertices.positions.joinToString(" "),
                vertices.textureCoordinates.joinToString(" "),
                colors, indices, blendMode.skiaCode(), paint.argb(),
            )
        }
    }

    override fun enableZ() {}

    override fun disableZ() {}
}

/** A canvas over an [ImageBitmap]'s backing surface (see [KlioImageBitmap]). */
internal actual fun ActualCanvas(image: ImageBitmap): Canvas =
    KlioCanvas(image.klioSurfaceHandle())

/**
 * klio helper: create an offscreen [width] x [height] surface, draw [block] onto
 * a real [Canvas], and save it as a PNG at [path]. No-op (returns false) when no
 * Skia backend is available, so it stays headless-safe. The real
 * `graphics.drawscope.DrawScope` render path wraps this same Canvas.
 */
/**
 * klio helper: draw [block] onto an EXISTING Skia surface handle (a window's
 * surface from `__composeui_winSurface`, or an offscreen `__skia_surf_new`).
 * The real ui engine's window driver renders frames through this.
 */
fun klioDrawToSurface(handle: Long, block: Canvas.() -> Unit) {
    if (handle == 0L) return
    KlioCanvas(handle).block()
}

fun klioDrawToPng(width: Int, height: Int, path: String, block: Canvas.() -> Unit): Boolean {
    val handle = __skia_surf_new(width, height)
    if (handle == 0L) return false
    KlioCanvas(handle).block()
    val ok = __skia_surf_save_png(handle, path) != 0L
    __skia_surf_free(handle)
    return ok
}

/**
 * klio helper: render a real [DrawScope] block onto an offscreen [width] x
 * [height] surface (at [density] px/dp) through the upstream [CanvasDrawScope],
 * and save it as a PNG. Returns false (no-op) when no Skia backend is present.
 * This is the DrawScope entry point — the same one a desktop Compose program's
 * `Canvas { … }` composable ultimately drives.
 */
fun klioRenderToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    block: DrawScope.() -> Unit,
): Boolean {
    val handle = __skia_surf_new(width, height)
    if (handle == 0L) return false
    CanvasDrawScope().draw(
        Density(density),
        LayoutDirection.Ltr,
        KlioCanvas(handle),
        Size(width.toFloat(), height.toFloat()),
        block,
    )
    val ok = __skia_surf_save_png(handle, path) != 0L
    __skia_surf_free(handle)
    return ok
}
