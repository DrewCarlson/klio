/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The klio [Path] actual: a pure-Kotlin command buffer of primitive verbs
 * (move / line / quadratic / cubic / close). Higher-level shapes (rectangles,
 * ovals, rounded rectangles, arcs) are decomposed into cubic segments when they
 * are added, so the buffer is uniform — which keeps [getBounds], iteration
 * ([PathIterator]), and native rasterization (the draw pass serializes the same
 * verbs) all trivial and consistent.
 *
 * Control-point bounds are tracked incrementally, matching Skia's fast bounds.
 */
internal class KlioPath : Path {
    // Verb codes, with fixed point arity (pairs of floats in [pts]).
    //   MOVE=1pt  LINE=1pt  QUAD=2pts  CUBIC=3pts  CLOSE=0pts
    internal val verbs = ArrayList<Int>()
    internal val pts = ArrayList<Float>() // flat x,y pairs

    private var curX = 0f
    private var curY = 0f
    private var startX = 0f
    private var startY = 0f

    private var minX = Float.POSITIVE_INFINITY
    private var minY = Float.POSITIVE_INFINITY
    private var maxX = Float.NEGATIVE_INFINITY
    private var maxY = Float.NEGATIVE_INFINITY
    private var pointCount = 0

    // True while the path is exactly one convex primitive (a single rect / oval /
    // rounded rect) and nothing else — the only shapes we report as convex.
    private var singlePrimitive = false
    private var mutatedAfterPrimitive = false

    override var fillType: PathFillType = PathFillType.NonZero

    override val isEmpty: Boolean
        get() = verbs.isEmpty()

    override val isConvex: Boolean
        get() = singlePrimitive && !mutatedAfterPrimitive

    private fun include(x: Float, y: Float) {
        if (x < minX) minX = x
        if (y < minY) minY = y
        if (x > maxX) maxX = x
        if (y > maxY) maxY = y
        pointCount++
    }

    private fun emitMove(x: Float, y: Float) {
        verbs.add(VERB_MOVE)
        pts.add(x); pts.add(y)
        curX = x; curY = y
        startX = x; startY = y
        include(x, y)
    }

    private fun emitLine(x: Float, y: Float) {
        verbs.add(VERB_LINE)
        pts.add(x); pts.add(y)
        curX = x; curY = y
        include(x, y)
    }

    private fun emitQuad(x1: Float, y1: Float, x2: Float, y2: Float) {
        verbs.add(VERB_QUAD)
        pts.add(x1); pts.add(y1); pts.add(x2); pts.add(y2)
        curX = x2; curY = y2
        include(x1, y1); include(x2, y2)
    }

    private fun emitCubic(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float) {
        verbs.add(VERB_CUBIC)
        pts.add(x1); pts.add(y1); pts.add(x2); pts.add(y2); pts.add(x3); pts.add(y3)
        curX = x3; curY = y3
        include(x1, y1); include(x2, y2); include(x3, y3)
    }

    private fun emitClose() {
        verbs.add(VERB_CLOSE)
        curX = startX; curY = startY
    }

    private fun markMutated() {
        if (verbs.isNotEmpty()) mutatedAfterPrimitive = true
    }

    override fun moveTo(x: Float, y: Float) { markMutated(); emitMove(x, y) }

    override fun relativeMoveTo(dx: Float, dy: Float) = moveTo(curX + dx, curY + dy)

    override fun lineTo(x: Float, y: Float) { markMutated(); emitLine(x, y) }

    override fun relativeLineTo(dx: Float, dy: Float) = lineTo(curX + dx, curY + dy)

    @Deprecated("Use quadraticTo() for consistency with cubicTo()")
    override fun quadraticBezierTo(x1: Float, y1: Float, x2: Float, y2: Float) {
        markMutated(); emitQuad(x1, y1, x2, y2)
    }

    override fun relativeQuadraticBezierTo(dx1: Float, dy1: Float, dx2: Float, dy2: Float) {
        markMutated(); emitQuad(curX + dx1, curY + dy1, curX + dx2, curY + dy2)
    }

    override fun cubicTo(x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float) {
        markMutated(); emitCubic(x1, y1, x2, y2, x3, y3)
    }

    override fun relativeCubicTo(dx1: Float, dy1: Float, dx2: Float, dy2: Float, dx3: Float, dy3: Float) {
        markMutated()
        emitCubic(curX + dx1, curY + dy1, curX + dx2, curY + dy2, curX + dx3, curY + dy3)
    }

    override fun arcToRad(
        rect: Rect,
        startAngleRadians: Float,
        sweepAngleRadians: Float,
        forceMoveTo: Boolean,
    ) {
        markMutated()
        arcTo(rect, startAngleRadians, sweepAngleRadians, forceMoveTo, degrees = false)
    }

    override fun arcTo(
        rect: Rect,
        startAngleDegrees: Float,
        sweepAngleDegrees: Float,
        forceMoveTo: Boolean,
    ) {
        markMutated()
        arcTo(
            rect,
            startAngleDegrees * DEG_TO_RAD,
            sweepAngleDegrees * DEG_TO_RAD,
            forceMoveTo,
            degrees = false,
        )
    }

    /** Adds an elliptical arc (angles in radians) as one or more cubic segments. */
    private fun arcTo(
        rect: Rect,
        startRad: Float,
        sweepRad: Float,
        forceMoveTo: Boolean,
        @Suppress("UNUSED_PARAMETER") degrees: Boolean,
    ) {
        val cx = rect.center.x
        val cy = rect.center.y
        val rx = rect.width / 2f
        val ry = rect.height / 2f
        val startX = cx + rx * cos(startRad)
        val startY = cy + ry * sin(startRad)
        if (forceMoveTo || verbs.isEmpty()) {
            emitMove(startX, startY)
        } else {
            emitLine(startX, startY)
        }
        appendArcCubics(cx, cy, rx, ry, startRad, sweepRad)
    }

    /** Emits cubic segments approximating the arc, splitting into <=90 degree pieces. */
    private fun appendArcCubics(
        cx: Float,
        cy: Float,
        rx: Float,
        ry: Float,
        startRad: Float,
        sweepRad: Float,
    ) {
        if (sweepRad == 0f) return
        val segments = max(1, ceil(abs(sweepRad) / (PI.toFloat() / 2f)).toInt())
        val delta = sweepRad / segments
        val kappa = (4.0 / 3.0 * kotlin.math.tan(delta.toDouble() / 4.0)).toFloat()
        var angle = startRad
        for (i in 0 until segments) {
            val a0 = angle
            val a1 = angle + delta
            val cosA0 = cos(a0); val sinA0 = sin(a0)
            val cosA1 = cos(a1); val sinA1 = sin(a1)
            val p1x = cx + rx * cosA0
            val p1y = cy + ry * sinA0
            val p2x = cx + rx * cosA1
            val p2y = cy + ry * sinA1
            val c1x = p1x - kappa * rx * sinA0
            val c1y = p1y + kappa * ry * cosA0
            val c2x = p2x + kappa * rx * sinA1
            val c2y = p2y - kappa * ry * cosA1
            emitCubic(c1x, c1y, c2x, c2y, p2x, p2y)
            angle = a1
        }
    }

    override fun addRect(rect: Rect) = addRect(rect, Path.Direction.CounterClockwise)

    override fun addRect(rect: Rect, direction: Path.Direction) {
        val wasEmpty = verbs.isEmpty()
        emitMove(rect.left, rect.top)
        if (direction == Path.Direction.Clockwise) {
            emitLine(rect.right, rect.top)
            emitLine(rect.right, rect.bottom)
            emitLine(rect.left, rect.bottom)
        } else {
            emitLine(rect.left, rect.bottom)
            emitLine(rect.right, rect.bottom)
            emitLine(rect.right, rect.top)
        }
        emitClose()
        setPrimitive(wasEmpty)
    }

    override fun addOval(oval: Rect) = addOval(oval, Path.Direction.CounterClockwise)

    override fun addOval(oval: Rect, direction: Path.Direction) {
        val wasEmpty = verbs.isEmpty()
        val cx = oval.center.x
        val cy = oval.center.y
        val rx = oval.width / 2f
        val ry = oval.height / 2f
        val sweep = if (direction == Path.Direction.Clockwise) 2f * PI.toFloat() else -2f * PI.toFloat()
        emitMove(cx + rx, cy)
        appendArcCubics(cx, cy, rx, ry, 0f, sweep)
        emitClose()
        setPrimitive(wasEmpty)
    }

    override fun addRoundRect(roundRect: RoundRect) =
        addRoundRect(roundRect, Path.Direction.CounterClockwise)

    override fun addRoundRect(roundRect: RoundRect, direction: Path.Direction) {
        val wasEmpty = verbs.isEmpty()
        val l = roundRect.left
        val t = roundRect.top
        val r = roundRect.right
        val b = roundRect.bottom
        val tlx = roundRect.topLeftCornerRadius.x
        val tly = roundRect.topLeftCornerRadius.y
        val trx = roundRect.topRightCornerRadius.x
        val tryy = roundRect.topRightCornerRadius.y
        val brx = roundRect.bottomRightCornerRadius.x
        val bry = roundRect.bottomRightCornerRadius.y
        val blx = roundRect.bottomLeftCornerRadius.x
        val bly = roundRect.bottomLeftCornerRadius.y
        val half = PI.toFloat() / 2f
        if (direction == Path.Direction.Clockwise) {
            emitMove(l + tlx, t)
            emitLine(r - trx, t)
            appendArcCubics(r - trx, t + tryy, trx, tryy, -half, half)
            emitLine(r, b - bry)
            appendArcCubics(r - brx, b - bry, brx, bry, 0f, half)
            emitLine(l + blx, b)
            appendArcCubics(l + blx, b - bly, blx, bly, half, half)
            emitLine(l, t + tly)
            appendArcCubics(l + tlx, t + tly, tlx, tly, PI.toFloat(), half)
        } else {
            emitMove(l + tlx, t)
            appendArcCubics(l + tlx, t + tly, tlx, tly, -half, -half)
            emitLine(l, b - bly)
            appendArcCubics(l + blx, b - bly, blx, bly, PI.toFloat(), -half)
            emitLine(r - brx, b)
            appendArcCubics(r - brx, b - bry, brx, bry, half, -half)
            emitLine(r, t + tryy)
            appendArcCubics(r - trx, t + tryy, trx, tryy, 0f, -half)
        }
        emitClose()
        setPrimitive(wasEmpty)
    }

    override fun addArcRad(oval: Rect, startAngleRadians: Float, sweepAngleRadians: Float) {
        markMutated()
        arcTo(oval, startAngleRadians, sweepAngleRadians, forceMoveTo = true, degrees = false)
    }

    override fun addArc(oval: Rect, startAngleDegrees: Float, sweepAngleDegrees: Float) {
        markMutated()
        arcTo(
            oval,
            startAngleDegrees * DEG_TO_RAD,
            sweepAngleDegrees * DEG_TO_RAD,
            forceMoveTo = true,
            degrees = false,
        )
    }

    override fun addPath(path: Path, offset: Offset) {
        markMutated()
        val other = path as? KlioPath ?: return
        var i = 0
        var p = 0
        val v = other.verbs
        val d = other.pts
        while (i < v.size) {
            when (v[i]) {
                VERB_MOVE -> { emitMove(d[p] + offset.x, d[p + 1] + offset.y); p += 2 }
                VERB_LINE -> { emitLine(d[p] + offset.x, d[p + 1] + offset.y); p += 2 }
                VERB_QUAD -> {
                    emitQuad(d[p] + offset.x, d[p + 1] + offset.y, d[p + 2] + offset.x, d[p + 3] + offset.y)
                    p += 4
                }
                VERB_CUBIC -> {
                    emitCubic(
                        d[p] + offset.x, d[p + 1] + offset.y,
                        d[p + 2] + offset.x, d[p + 3] + offset.y,
                        d[p + 4] + offset.x, d[p + 5] + offset.y,
                    )
                    p += 6
                }
                VERB_CLOSE -> emitClose()
            }
            i++
        }
    }

    override fun close() { markMutated(); emitClose() }

    override fun reset() {
        verbs.clear()
        pts.clear()
        curX = 0f; curY = 0f; startX = 0f; startY = 0f
        minX = Float.POSITIVE_INFINITY; minY = Float.POSITIVE_INFINITY
        maxX = Float.NEGATIVE_INFINITY; maxY = Float.NEGATIVE_INFINITY
        pointCount = 0
        singlePrimitive = false
        mutatedAfterPrimitive = false
        fillType = PathFillType.NonZero
    }

    override fun translate(offset: Offset) {
        var i = 0
        while (i < pts.size) {
            pts[i] = pts[i] + offset.x
            pts[i + 1] = pts[i + 1] + offset.y
            i += 2
        }
        if (pointCount > 0) {
            minX += offset.x; maxX += offset.x
            minY += offset.y; maxY += offset.y
        }
        curX += offset.x; curY += offset.y
        startX += offset.x; startY += offset.y
    }

    override fun getBounds(): Rect {
        if (pointCount <= 1) return Rect.Zero
        return Rect(minX, minY, maxX, maxY)
    }

    override fun op(path1: Path, path2: Path, operation: PathOperation): Boolean {
        // Boolean path operations require the native rasterizer; wired to the Skia
        // shim in a follow-up. Union/Difference/Intersect/Xor are not yet available
        // through the pure-Kotlin path.
        throw NotImplementedError("Path boolean operations are not yet supported")
    }

    private fun setPrimitive(wasEmpty: Boolean) {
        if (wasEmpty) {
            singlePrimitive = true
            mutatedAfterPrimitive = false
        } else {
            mutatedAfterPrimitive = true
        }
    }

    internal companion object {
        const val VERB_MOVE = 1
        const val VERB_LINE = 2
        const val VERB_QUAD = 3
        const val VERB_CUBIC = 4
        const val VERB_CLOSE = 5
        const val DEG_TO_RAD = (PI / 180.0).toFloat()
    }
}

/** The klio [Path] factory actual. */
actual fun Path(): Path = KlioPath()
