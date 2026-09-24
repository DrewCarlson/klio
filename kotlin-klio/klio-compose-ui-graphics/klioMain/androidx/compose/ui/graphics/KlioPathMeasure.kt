/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Offset
import kotlin.math.ceil
import kotlin.math.sqrt

/**
 * The klio [PathMeasure] actual, in plain Kotlin over [PathIterator]. It follows
 * Skia's contour measure, which the desktop actual wraps: [setPath] measures the
 * path's first contour of non-zero length, every query is about that contour,
 * and distances are pinned to `0..length`. Curves are sampled into a
 * distance table; a position is found by interpolating the curve parameter
 * between samples and evaluating the curve there, and [getSegment] emits the
 * exact sub-curves between the two parameters.
 */
internal class KlioPathMeasure : PathMeasure {
    /** One line, quadratic or cubic of the contour, with its distance table. */
    private class Segment(
        val type: PathSegment.Type,
        val points: FloatArray,
        /** Curve parameters of the samples, from 0 to 1. */
        val ts: FloatArray,
        /** Contour distance at each sample. */
        val ds: FloatArray,
    )

    private val segments = ArrayList<Segment>()
    private var total = 0f

    override val length: Float
        get() = total

    override fun setPath(path: Path?, forceClosed: Boolean) {
        segments.clear()
        total = 0f
        if (path == null) return
        val iterator = PathIterator(path)
        val points = FloatArray(8)
        var startX = 0f
        var startY = 0f
        var lastX = 0f
        var lastY = 0f
        while (iterator.hasNext()) {
            when (val type = iterator.next(points, 0)) {
                PathSegment.Type.Move -> {
                    if (segments.isNotEmpty()) {
                        if (finishContour(forceClosed, startX, startY, lastX, lastY)) return
                    }
                    startX = points[0]
                    startY = points[1]
                    lastX = startX
                    lastY = startY
                }
                PathSegment.Type.Line,
                PathSegment.Type.Quadratic,
                PathSegment.Type.Cubic -> {
                    val n = when (type) {
                        PathSegment.Type.Line -> 4
                        PathSegment.Type.Quadratic -> 6
                        else -> 8
                    }
                    addSegment(type, points.copyOf(n))
                    lastX = points[n - 2]
                    lastY = points[n - 1]
                }
                PathSegment.Type.Close -> {
                    if (lastX != startX || lastY != startY) {
                        addSegment(PathSegment.Type.Line, floatArrayOf(lastX, lastY, startX, startY))
                    }
                    lastX = startX
                    lastY = startY
                    if (finishContour(false, startX, startY, lastX, lastY)) return
                }
                // Done ends the walk; conics arrive converted to quadratics.
                else -> {}
            }
        }
        if (segments.isNotEmpty()) finishContour(forceClosed, startX, startY, lastX, lastY)
    }

    /**
     * Ends the contour being measured: closes it when [forceClosed] asks, and
     * keeps it when it has length. A contour without length is dropped so the
     * next one is measured instead. Returns whether the contour was kept.
     */
    private fun finishContour(
        forceClosed: Boolean,
        startX: Float,
        startY: Float,
        lastX: Float,
        lastY: Float,
    ): Boolean {
        if (forceClosed && (lastX != startX || lastY != startY)) {
            addSegment(PathSegment.Type.Line, floatArrayOf(lastX, lastY, startX, startY))
        }
        if (total > 0f) return true
        segments.clear()
        total = 0f
        return false
    }

    private fun addSegment(type: PathSegment.Type, points: FloatArray) {
        val samples =
            if (type == PathSegment.Type.Line) {
                1
            } else {
                var polygon = 0f
                var i = 2
                while (i < points.size) {
                    polygon += distance(points[i - 2], points[i - 1], points[i], points[i + 1])
                    i += 2
                }
                ceil(sqrt(polygon) * 2f).toInt().coerceIn(8, 128)
            }
        val ts = FloatArray(samples + 1)
        val ds = FloatArray(samples + 1)
        ds[0] = total
        var px = points[0]
        var py = points[1]
        for (k in 1..samples) {
            val t = k.toFloat() / samples
            val x = evaluate(type, points, t, 0)
            val y = evaluate(type, points, t, 1)
            ts[k] = t
            ds[k] = ds[k - 1] + distance(px, py, x, y)
            px = x
            py = y
        }
        total = ds[samples]
        segments.add(Segment(type, points, ts, ds))
    }

    /** Index of the segment holding contour distance [d]. */
    private fun segmentAt(d: Float): Int {
        for (i in segments.indices) {
            if (d <= segments[i].ds[segments[i].ds.size - 1]) return i
        }
        return segments.size - 1
    }

    /** The curve parameter of segment [index] at contour distance [d]. */
    private fun parameterAt(index: Int, d: Float): Float {
        val seg = segments[index]
        val ds = seg.ds
        var k = 1
        while (k < ds.size - 1 && ds[k] < d) k++
        val span = ds[k] - ds[k - 1]
        val f = if (span > 0f) ((d - ds[k - 1]) / span).coerceIn(0f, 1f) else 0f
        return seg.ts[k - 1] + (seg.ts[k] - seg.ts[k - 1]) * f
    }

    private fun pin(distance: Float): Float = distance.coerceIn(0f, total)

    override fun getPosition(distance: Float): Offset {
        if (segments.isEmpty() || distance.isNaN()) return Offset.Unspecified
        val d = pin(distance)
        val index = segmentAt(d)
        val seg = segments[index]
        val t = parameterAt(index, d)
        return Offset(evaluate(seg.type, seg.points, t, 0), evaluate(seg.type, seg.points, t, 1))
    }

    override fun getTangent(distance: Float): Offset {
        if (segments.isEmpty() || distance.isNaN()) return Offset.Unspecified
        val d = pin(distance)
        val index = segmentAt(d)
        val seg = segments[index]
        val t = parameterAt(index, d)
        val dx = derivative(seg.type, seg.points, t, 0)
        val dy = derivative(seg.type, seg.points, t, 1)
        val len = sqrt(dx * dx + dy * dy)
        return if (len > 0f) Offset(dx / len, dy / len) else Offset.Zero
    }

    override fun getSegment(
        startDistance: Float,
        stopDistance: Float,
        destination: Path,
        startWithMoveTo: Boolean,
    ): Boolean {
        val start = if (startDistance < 0f) 0f else startDistance
        val stop = if (stopDistance > total) total else stopDistance
        if (!(start <= stop) || segments.isEmpty()) return false
        val startIndex = segmentAt(start)
        val startT = parameterAt(startIndex, start)
        val stopIndex = segmentAt(stop)
        val stopT = parameterAt(stopIndex, stop)
        if (startWithMoveTo) {
            val seg = segments[startIndex]
            destination.moveTo(
                evaluate(seg.type, seg.points, startT, 0),
                evaluate(seg.type, seg.points, startT, 1),
            )
        }
        if (startIndex == stopIndex) {
            segmentTo(segments[startIndex], startT, stopT, destination)
        } else {
            segmentTo(segments[startIndex], startT, 1f, destination)
            for (i in startIndex + 1 until stopIndex) segmentTo(segments[i], 0f, 1f, destination)
            segmentTo(segments[stopIndex], 0f, stopT, destination)
        }
        return true
    }

    /** Appends the part of [seg] between parameters [t0] and [t1] to [dst]. */
    private fun segmentTo(seg: Segment, t0: Float, t1: Float, dst: Path) {
        val p = seg.points
        if (t0 == t1) {
            if (!dst.isEmpty) {
                dst.lineTo(evaluate(seg.type, p, t1, 0), evaluate(seg.type, p, t1, 1))
            }
            return
        }
        when (seg.type) {
            PathSegment.Type.Line ->
                dst.lineTo(evaluate(seg.type, p, t1, 0), evaluate(seg.type, p, t1, 1))
            PathSegment.Type.Quadratic -> {
                val q = subCurve(p, 3, t0, t1)
                dst.quadraticTo(q[2], q[3], q[4], q[5])
            }
            else -> {
                val c = subCurve(p, 4, t0, t1)
                dst.cubicTo(c[2], c[3], c[4], c[5], c[6], c[7])
            }
        }
    }

    private companion object {
        fun distance(x0: Float, y0: Float, x1: Float, y1: Float): Float {
            val dx = x1 - x0
            val dy = y1 - y0
            return sqrt(dx * dx + dy * dy)
        }

        /** Coordinate [axis] (0 = x, 1 = y) of the curve at parameter [t]. */
        fun evaluate(type: PathSegment.Type, p: FloatArray, t: Float, axis: Int): Float {
            val u = 1f - t
            return when (type) {
                PathSegment.Type.Line -> p[axis] * u + p[2 + axis] * t
                PathSegment.Type.Quadratic ->
                    u * u * p[axis] + 2f * u * t * p[2 + axis] + t * t * p[4 + axis]
                else ->
                    u * u * u * p[axis] + 3f * u * u * t * p[2 + axis] +
                        3f * u * t * t * p[4 + axis] + t * t * t * p[6 + axis]
            }
        }

        /** Derivative of coordinate [axis] with respect to the parameter at [t]. */
        fun derivative(type: PathSegment.Type, p: FloatArray, t: Float, axis: Int): Float {
            val u = 1f - t
            return when (type) {
                PathSegment.Type.Line -> p[2 + axis] - p[axis]
                PathSegment.Type.Quadratic ->
                    2f * u * (p[2 + axis] - p[axis]) + 2f * t * (p[4 + axis] - p[2 + axis])
                else ->
                    3f * u * u * (p[2 + axis] - p[axis]) +
                        6f * u * t * (p[4 + axis] - p[2 + axis]) +
                        3f * t * t * (p[6 + axis] - p[4 + axis])
            }
        }

        /**
         * The control points of the part of a Bezier curve of [order] points
         * between parameters [t0] and [t1], by two de Casteljau splits.
         */
        fun subCurve(p: FloatArray, order: Int, t0: Float, t1: Float): FloatArray {
            val tail = splitAfter(p.copyOf(order * 2), order, t0)
            val rest = if (t0 < 1f) (t1 - t0) / (1f - t0) else 1f
            return splitBefore(tail, order, rest)
        }

        /** The curve's part after parameter [t]. */
        fun splitAfter(p: FloatArray, order: Int, t: Float): FloatArray {
            val w = p.copyOf()
            val out = FloatArray(order * 2)
            for (level in order - 1 downTo 0) {
                out[level * 2] = w[level * 2]
                out[level * 2 + 1] = w[level * 2 + 1]
                for (i in 0 until level) {
                    w[i * 2] = w[i * 2] + (w[i * 2 + 2] - w[i * 2]) * t
                    w[i * 2 + 1] = w[i * 2 + 1] + (w[i * 2 + 3] - w[i * 2 + 1]) * t
                }
            }
            // The last point of each level, deepest first: the split point, then
            // on to the curve's end point.
            return out
        }

        /** The curve's part before parameter [t]. */
        fun splitBefore(p: FloatArray, order: Int, t: Float): FloatArray {
            val w = p.copyOf()
            val curve = FloatArray(order * 2)
            for (level in 0 until order) {
                curve[level * 2] = w[0]
                curve[level * 2 + 1] = w[1]
                for (i in 0 until order - 1 - level) {
                    w[i * 2] = w[i * 2] + (w[i * 2 + 2] - w[i * 2]) * t
                    w[i * 2 + 1] = w[i * 2 + 1] + (w[i * 2 + 3] - w[i * 2 + 1]) * t
                }
            }
            return curve
        }
    }
}

/** The klio [PathMeasure] factory actual. */
actual fun PathMeasure(): PathMeasure = KlioPathMeasure()
