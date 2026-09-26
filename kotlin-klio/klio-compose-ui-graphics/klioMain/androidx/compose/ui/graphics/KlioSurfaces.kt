/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import klio.skia.wrapCanvas

// klio's surfaces: Skia surfaces the host owns (a window's frame, a tray
// icon, a menu, an offscreen image saved as a PNG). Drawing on one goes
// through skiko's Canvas over the surface's SkCanvas, as Compose Desktop
// draws a frame through skiko's.

/**
 * Draws [block] onto the host surface [handle] (a window's frame from
 * `__composeui_winSurface`, or one from `__skia_surf_new`). Nothing is drawn
 * without a Skia backend.
 */
fun klioDrawToSurface(handle: Long, block: Canvas.() -> Unit) {
    if (handle == 0L) return
    val pointer = __skia_surf_canvas(handle)
    if (pointer == 0L) return
    wrapCanvas(pointer, handle).asComposeCanvas().block()
}

/**
 * Draws [block] onto an offscreen [width] x [height] surface and saves it as a
 * PNG at [path]. False, drawing nothing, without a Skia backend.
 */
fun klioDrawToPng(width: Int, height: Int, path: String, block: Canvas.() -> Unit): Boolean {
    val handle = __skia_surf_new(width, height)
    if (handle == 0L) return false
    klioDrawToSurface(handle, block)
    val ok = __skia_surf_save_png(handle, path) != 0L
    __skia_surf_free(handle)
    return ok
}

/**
 * Renders a [DrawScope] block onto an offscreen [width] x [height] surface at
 * [density] pixels per dp through the upstream [CanvasDrawScope], the one a
 * desktop Compose `Canvas { }` drives, and saves it as a PNG at [path]. False,
 * drawing nothing, without a Skia backend.
 */
fun klioRenderToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    block: DrawScope.() -> Unit,
): Boolean = klioDrawToPng(width, height, path) {
    CanvasDrawScope().draw(
        Density(density),
        LayoutDirection.Ltr,
        this,
        Size(width.toFloat(), height.toFloat()),
        block,
    )
}

// The host's surfaces (src/compose_ui): a handle is an opaque Long, 0 when no
// Skia backend is present.
internal fun __skia_surf_new(width: Int, height: Int): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_new not installed")

internal fun __skia_surf_save_png(handle: Long, path: String): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_save_png not installed")

internal fun __skia_surf_free(handle: Long): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_free not installed")

// The SkCanvas* the surface's draws go to.
internal fun __skia_surf_canvas(handle: Long): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_canvas not installed")
