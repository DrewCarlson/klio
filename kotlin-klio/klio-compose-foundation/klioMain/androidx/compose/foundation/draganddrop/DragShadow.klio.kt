/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.draganddrop

import androidx.compose.ui.draw.CacheDrawScope
import androidx.compose.ui.draw.DrawResult
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.draw
import kotlin.math.ceil

/**
 * The default drag shadow: each draw of the source caches what it drew, and the
 * drag decoration draws that cache. skiko records the content as a Skia
 * Picture (DragAndDropSource.skiko.kt); klio records it into an ImageBitmap of
 * the source's size, which draws back the same pixels.
 */
internal actual class CacheDrawScopeDragShadowCallback {
    private var cachedImage: ImageBitmap? = null

    actual fun drawDragShadow(drawScope: DrawScope) =
        with(drawScope) {
            when (val image = cachedImage) {
                null ->
                    throw IllegalArgumentException(
                        "No cached drag shadow. Check if Modifier.cacheDragShadow(painter) was called."
                    )
                else -> drawImage(image)
            }
        }

    actual fun cachePicture(scope: CacheDrawScope): DrawResult =
        with(scope) {
            val width = ceil(size.width).toInt().coerceAtLeast(1)
            val height = ceil(size.height).toInt().coerceAtLeast(1)
            onDrawWithContent {
                val image = ImageBitmap(width, height)
                draw(
                    density = this,
                    layoutDirection = this.layoutDirection,
                    canvas = Canvas(image),
                    size = this.size
                ) {
                    this@onDrawWithContent.drawContent()
                }
                cachedImage = image
                drawImage(image)
            }
        }
}
