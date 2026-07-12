/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.graphics.colorspace.ColorSpace
import androidx.compose.ui.graphics.colorspace.ColorSpaces

/**
 * The klio [ImageBitmap]: an offscreen Skia surface. Drawing reaches it through
 * [ActualCanvas] (a [KlioCanvas] over the same handle); [Canvas.drawImage] blits
 * it onto another surface via a snapshot. Headless (no Skia backend) the handle
 * is 0: draws no-op and [readPixels] reports transparent black, so programs stay
 * runnable without the native library.
 */
internal class KlioImageBitmap(
    override val width: Int,
    override val height: Int,
    override val config: ImageBitmapConfig,
    override val hasAlpha: Boolean,
    override val colorSpace: ColorSpace,
) : ImageBitmap {
    internal val handle: Long = __skia_surf_new(width, height)

    override fun readPixels(
        buffer: IntArray,
        startX: Int,
        startY: Int,
        width: Int,
        height: Int,
        bufferOffset: Int,
        stride: Int,
    ) {
        var row = 0
        while (row < height) {
            var col = 0
            while (col < width) {
                buffer[bufferOffset + row * stride + col] =
                    __skia_surf_pixel(handle, startX + col, startY + row).toInt()
                col++
            }
            row++
        }
    }

    override fun prepareToDraw() {}
}

internal fun ImageBitmap.klioSurfaceHandle(): Long =
    (this as? KlioImageBitmap)?.handle ?: 0L
