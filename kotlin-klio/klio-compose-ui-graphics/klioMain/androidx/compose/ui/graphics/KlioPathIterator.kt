/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

/**
 * The klio [PathIterator] actual: walks a [KlioPath]'s primitive verb buffer,
 * emitting one [PathSegment] per verb. Because higher-level shapes are already
 * decomposed to cubics when added, there are no conic segments to evaluate, so
 * [conicEvaluation]/[tolerance] have no effect here.
 */
internal class KlioPathIterator(
    override val path: Path,
    override val conicEvaluation: PathIterator.ConicEvaluation,
    override val tolerance: Float,
) : PathIterator {
    private val verbs = (path as? KlioPath)?.verbs ?: ArrayList()
    private val pts = (path as? KlioPath)?.pts ?: ArrayList()
    private var vi = 0
    private var pi = 0
    private var curX = 0f
    private var curY = 0f
    private var startX = 0f
    private var startY = 0f

    override fun calculateSize(includeConvertedConics: Boolean): Int = verbs.size

    override fun hasNext(): Boolean = vi < verbs.size

    override fun next(outPoints: FloatArray, offset: Int): PathSegment.Type {
        if (vi >= verbs.size) return PathSegment.Type.Done
        return when (verbs[vi++]) {
            KlioPath.VERB_MOVE -> {
                val x = pts[pi++]; val y = pts[pi++]
                outPoints[offset] = x; outPoints[offset + 1] = y
                curX = x; curY = y; startX = x; startY = y
                PathSegment.Type.Move
            }
            KlioPath.VERB_LINE -> {
                val x = pts[pi++]; val y = pts[pi++]
                outPoints[offset] = curX; outPoints[offset + 1] = curY
                outPoints[offset + 2] = x; outPoints[offset + 3] = y
                curX = x; curY = y
                PathSegment.Type.Line
            }
            KlioPath.VERB_QUAD -> {
                val cx = pts[pi++]; val cy = pts[pi++]; val ex = pts[pi++]; val ey = pts[pi++]
                outPoints[offset] = curX; outPoints[offset + 1] = curY
                outPoints[offset + 2] = cx; outPoints[offset + 3] = cy
                outPoints[offset + 4] = ex; outPoints[offset + 5] = ey
                curX = ex; curY = ey
                PathSegment.Type.Quadratic
            }
            KlioPath.VERB_CUBIC -> {
                val c1x = pts[pi++]; val c1y = pts[pi++]
                val c2x = pts[pi++]; val c2y = pts[pi++]
                val ex = pts[pi++]; val ey = pts[pi++]
                outPoints[offset] = curX; outPoints[offset + 1] = curY
                outPoints[offset + 2] = c1x; outPoints[offset + 3] = c1y
                outPoints[offset + 4] = c2x; outPoints[offset + 5] = c2y
                outPoints[offset + 6] = ex; outPoints[offset + 7] = ey
                curX = ex; curY = ey
                PathSegment.Type.Cubic
            }
            else -> { // VERB_CLOSE
                curX = startX; curY = startY
                PathSegment.Type.Close
            }
        }
    }

    override fun next(): PathSegment {
        val tmp = FloatArray(8)
        val type = next(tmp, 0)
        val pairs = when (type) {
            PathSegment.Type.Move -> 1
            PathSegment.Type.Line -> 2
            PathSegment.Type.Quadratic -> 3
            PathSegment.Type.Cubic -> 4
            else -> 0
        }
        if (pairs == 0) {
            return if (type == PathSegment.Type.Close) CloseSegment else DoneSegment
        }
        return PathSegment(type, tmp.copyOf(pairs * 2), 0f)
    }
}

/** The klio [PathIterator] factory actual. */
actual fun PathIterator(
    path: Path,
    conicEvaluation: PathIterator.ConicEvaluation,
    tolerance: Float,
): PathIterator = KlioPathIterator(path, conicEvaluation, tolerance)
