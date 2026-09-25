/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// Whether a path is convex, decided from its points the way Skia decides it
// (SkPathPriv::ComputeConvexity and its Convexicator, skia m150), so a klio
// Path answers Path.isConvex as a skiko one does: every point of the path,
// curve control points included, must turn the same way around a single
// contour.
package androidx.compose.ui.graphics

import androidx.compose.ui.graphics.KlioPath.Companion.VERB_CLOSE
import androidx.compose.ui.graphics.KlioPath.Companion.VERB_CUBIC
import androidx.compose.ui.graphics.KlioPath.Companion.VERB_LINE
import androidx.compose.ui.graphics.KlioPath.Companion.VERB_MOVE
import androidx.compose.ui.graphics.KlioPath.Companion.VERB_QUAD

private const val DirUnknown = 0
private const val DirLeft = 1
private const val DirRight = 2
private const val DirStraight = 3
private const val DirBackwards = 4
private const val DirInvalid = 5

private const val FirstUnknown = 0
private const val FirstCw = 1
private const val FirstCcw = 2

private const val SignNever = 2

private fun pointsInVerb(verb: Int): Int = when (verb) {
    VERB_MOVE, VERB_LINE -> 1
    VERB_QUAD -> 2
    VERB_CUBIC -> 3
    else -> 0
}

/** The Convexicator of one contour. */
private class Convexicator {
    var firstX = 0f; var firstY = 0f
    var firstVecX = 0f; var firstVecY = 0f
    var lastX = 0f; var lastY = 0f
    var lastVecX = 0f; var lastVecY = 0f
    var expectedDir = DirInvalid
    var firstDirection = FirstUnknown
    var reversals = 0
    var isFinite = true

    fun setMovePt(x: Float, y: Float) {
        firstX = x; firstY = y
        lastX = x; lastY = y
        expectedDir = DirInvalid
    }

    fun addPt(x: Float, y: Float): Boolean {
        if (lastX == x && lastY == y) return true
        if (firstX == lastX && firstY == lastY && expectedDir == DirInvalid &&
            lastVecX == 0f && lastVecY == 0f
        ) {
            lastVecX = x - lastX; lastVecY = y - lastY
            firstVecX = lastVecX; firstVecY = lastVecY
        } else if (!addVec(x - lastX, y - lastY)) {
            return false
        }
        lastX = x; lastY = y
        return true
    }

    fun close(): Boolean = addPt(firstX, firstY) && addVec(firstVecX, firstVecY)

    private fun directionChange(vx: Float, vy: Float): Int {
        val cross = lastVecX * vy - lastVecY * vx
        if (!cross.isFinite()) return DirUnknown
        if (cross == 0f) {
            return if (lastVecX * vx + lastVecY * vy < 0f) DirBackwards else DirStraight
        }
        return if (cross > 0f) DirRight else DirLeft
    }

    private fun addVec(vx: Float, vy: Float): Boolean {
        when (val dir = directionChange(vx, vy)) {
            DirLeft, DirRight -> {
                if (expectedDir == DirInvalid) {
                    expectedDir = dir
                    firstDirection = if (dir == DirRight) FirstCw else FirstCcw
                } else if (dir != expectedDir) {
                    firstDirection = FirstUnknown
                    return false
                }
                lastVecX = vx; lastVecY = vy
            }
            DirStraight -> {}
            DirBackwards -> {
                // A path may reverse direction twice (a line drawn out and back).
                lastVecX = vx; lastVecY = vy
                return ++reversals < 3
            }
            else -> {
                isFinite = false
                return false
            }
        }
        return true
    }
}

/** Whether the direction of travel changes sign more than three times: concave. */
private fun isConcaveBySign(pts: List<Float>, count: Int): Boolean {
    if (count <= 3) return false // a point, a line or a triangle
    var currX = pts[0]; var currY = pts[1]
    val firstX = currX; val firstY = currY
    var dxes = 0
    var dyes = 0
    var lastSx = SignNever
    var lastSy = SignNever
    var i = 1
    for (outerLoop in 0 until 2) {
        while (true) {
            val px: Float
            val py: Float
            if (outerLoop == 0) {
                if (i >= count) break
                px = pts[2 * i]; py = pts[2 * i + 1]
            } else {
                px = firstX; py = firstY
            }
            val vx = px - currX
            val vy = py - currY
            if (vx != 0f || vy != 0f) {
                if (!vx.isFinite() || !vy.isFinite()) return true
                val sx = if (vx < 0f) 1 else 0
                val sy = if (vy < 0f) 1 else 0
                if (sx != lastSx) dxes++
                if (sy != lastSy) dyes++
                if (dxes > 3 || dyes > 3) return true
                lastSx = sx
                lastSy = sy
            }
            currX = px; currY = py
            i++
            if (outerLoop == 1) break
        }
    }
    return false
}

/** Whether the path of [verbs] over the flat x, y [pts] is convex. */
internal fun isConvexPath(verbs: List<Int>, pts: List<Float>): Boolean {
    for (v in pts) if (!v.isFinite()) return false
    // Trailing moves are ignored.
    var verbCount = verbs.size
    var pointCount = pts.size / 2
    while (verbCount > 0 && verbs[verbCount - 1] == VERB_MOVE) {
        verbCount--
        pointCount--
    }
    if (verbCount == 0) return true
    if (isConcaveBySign(pts, pointCount)) return false

    var contourCount = 0
    var needsClose = false
    val state = Convexicator()
    var p = 0 // the index of the verb's first point
    for (vi in 0 until verbCount) {
        val verb = verbs[vi]
        val n = pointsInVerb(verb)
        if (contourCount == 0) {
            if (verb == VERB_MOVE) {
                state.setMovePt(pts[2 * p], pts[2 * p + 1])
            } else {
                // The contour starts: its points are added below.
                contourCount++
                needsClose = true
            }
        }
        if (contourCount == 1) {
            if (verb == VERB_CLOSE || verb == VERB_MOVE) {
                if (!state.close()) return false
                needsClose = false
                contourCount++
            } else {
                for (k in 0 until n) {
                    if (!state.addPt(pts[2 * (p + k)], pts[2 * (p + k) + 1])) return false
                }
            }
        } else if (verb != VERB_MOVE) {
            // Anything but a trailing move after the first contour: a second contour.
            return false
        }
        p += n
    }
    if (needsClose && !state.close()) return false
    if (state.firstDirection == FirstUnknown && state.reversals >= 3) return false
    return true
}
