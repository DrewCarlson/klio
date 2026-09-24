/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.semantics

import androidx.compose.ui.unit.IntRect

/**
 * A region as a set of disjoint rectangles. skiko backs a semantics region
 * with a Skia `Region` (SemanticsRegion.skiko.kt); klio keeps the rectangles
 * itself, with the same answers: an operation reports whether the region it
 * leaves is non-empty, and an empty region's bounds are all zero.
 */
private class RectSetRegion : SemanticsRegion {
    var rects: List<IntRect> = emptyList()

    override fun set(rect: IntRect) {
        rects = if (rect.isEmpty) emptyList() else listOf(rect)
    }

    override val bounds: IntRect
        get() {
            if (rects.isEmpty()) return IntRect.Zero
            var left = Int.MAX_VALUE
            var top = Int.MAX_VALUE
            var right = Int.MIN_VALUE
            var bottom = Int.MIN_VALUE
            for (r in rects) {
                if (r.left < left) left = r.left
                if (r.top < top) top = r.top
                if (r.right > right) right = r.right
                if (r.bottom > bottom) bottom = r.bottom
            }
            return IntRect(left, top, right, bottom)
        }

    override val isEmpty: Boolean
        get() = rects.isEmpty()

    override fun intersect(region: SemanticsRegion): Boolean {
        val others = (region as RectSetRegion).rects
        val out = ArrayList<IntRect>()
        for (a in rects) {
            for (b in others) {
                val r = a.intersect(b)
                if (!r.isEmpty) out.add(r)
            }
        }
        rects = out
        return !isEmpty
    }

    override fun difference(rect: IntRect): Boolean {
        if (rect.isEmpty) return !isEmpty
        val out = ArrayList<IntRect>()
        for (r in rects) {
            if (!r.overlaps(rect)) {
                out.add(r)
                continue
            }
            // What of `r` lies above, below, left and right of `rect`.
            if (r.top < rect.top) out.add(IntRect(r.left, r.top, r.right, rect.top))
            if (rect.bottom < r.bottom) out.add(IntRect(r.left, rect.bottom, r.right, r.bottom))
            val midTop = maxOf(r.top, rect.top)
            val midBottom = minOf(r.bottom, rect.bottom)
            if (r.left < rect.left) out.add(IntRect(r.left, midTop, rect.left, midBottom))
            if (rect.right < r.right) out.add(IntRect(rect.right, midTop, r.right, midBottom))
        }
        rects = out
        return !isEmpty
    }
}

internal actual fun SemanticsRegion(): SemanticsRegion = RectSetRegion()
