/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

// Host intrinsics backed by the Skia shim (src/compose_ui). Registered by the
// compose_ui module's host bindings, which are installed for every pack program.

// Combines two serialized path command buffers with a boolean op (op: 0
// difference, 1 intersect, 2 union, 3 xor, 4 reverse-difference — matching
// PathOperation). Returns the result command buffer, or null on failure / when
// no Skia backend is present.
internal fun __skia_path_op(a: String, b: String, op: Int): String? =
    error("intrinsic androidx.compose.ui.graphics.__skia_path_op not installed")

// A drawing surface (handle = an opaque Long; 0 when no Skia backend). The Canvas
// actual draws onto it and the render entry point saves / frees it.
internal fun __skia_surf_new(width: Int, height: Int): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_new not installed")

internal fun __skia_surf_save_png(handle: Long, path: String): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_save_png not installed")

internal fun __skia_surf_free(handle: Long): Long =
    error("intrinsic androidx.compose.ui.graphics.__skia_surf_free not installed")

// SkCanvas operations on the surface. The packed paint tail is
// (argb, style, strokeWidth, cap, join, aa).
internal fun __skia_c_save(handle: Long): Long = error("intrinsic __skia_c_save not installed")
internal fun __skia_c_restore(handle: Long): Long = error("intrinsic __skia_c_restore not installed")
internal fun __skia_c_translate(handle: Long, dx: Float, dy: Float): Long = error("intrinsic __skia_c_translate not installed")
internal fun __skia_c_scale(handle: Long, sx: Float, sy: Float): Long = error("intrinsic __skia_c_scale not installed")
internal fun __skia_c_rotate(handle: Long, degrees: Float): Long = error("intrinsic __skia_c_rotate not installed")
internal fun __skia_c_skew(handle: Long, sx: Float, sy: Float): Long = error("intrinsic __skia_c_skew not installed")
internal fun __skia_c_clip_rect(handle: Long, l: Float, t: Float, r: Float, b: Float, clipOp: Int): Long = error("intrinsic __skia_c_clip_rect not installed")
internal fun __skia_c_clip_path(handle: Long, pathText: String, clipOp: Int): Long = error("intrinsic __skia_c_clip_path not installed")
internal fun __skia_c_set_shader(handle: Long, gradientText: String): Long = error("intrinsic __skia_c_set_shader not installed")
internal fun __skia_c_set_blur(handle: Long, sigma: Float): Long = error("intrinsic __skia_c_set_blur not installed")
internal fun __skia_c_set_color_filter(handle: Long, argb: Int, mode: Int): Long = error("intrinsic __skia_c_set_color_filter not installed")
// The next draws' blend mode (skiaCode) and the alpha an image draw composites
// with; a negative mode resets both.
internal fun __skia_c_set_paint_state(handle: Long, mode: Int, imageAlpha: Float): Long = error("intrinsic __skia_c_set_paint_state not installed")
internal fun __skia_c_draw_rect(handle: Long, l: Float, t: Float, r: Float, b: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_rect not installed")
internal fun __skia_c_draw_rrect(handle: Long, l: Float, t: Float, r: Float, b: Float, rx: Float, ry: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_rrect not installed")
internal fun __skia_c_draw_oval(handle: Long, l: Float, t: Float, r: Float, b: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_oval not installed")
internal fun __skia_c_draw_circle(handle: Long, cx: Float, cy: Float, radius: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_circle not installed")
internal fun __skia_c_draw_line(handle: Long, x0: Float, y0: Float, x1: Float, y1: Float, argb: Int, sw: Float, cap: Int, aa: Int): Long = error("intrinsic __skia_c_draw_line not installed")
internal fun __skia_c_draw_path(handle: Long, pathText: String, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_path not installed")

// Text: draw a single run with its baseline origin at (x, y) onto the canvas
// (honouring its transform/clip); measure a run's advance width; read a font
// vertical metric (which: 0 ascent<0, 1 descent>0, 2 leading) at a pixel size.
internal fun __skia_c_draw_text(handle: Long, text: String, x: Float, y: Float, sizePx: Float, argb: Int): Long = error("intrinsic __skia_c_draw_text not installed")
// A styled run: flags bit0 bold, bit1 italic, bit2 underline, bit3 strikethrough.
internal fun __skia_c_draw_text2(handle: Long, text: String, x: Float, y: Float, sizePx: Float, argb: Int, flags: Int): Long = error("intrinsic __skia_c_draw_text2 not installed")
internal fun __composeui_text_width(text: String, sizePx: Float): Float = error("intrinsic __composeui_text_width not installed")
internal fun __composeui_font_metric(sizePx: Float, which: Int): Float = error("intrinsic __composeui_font_metric not installed")
internal fun __skia_c_concat(handle: Long, sx: Float, kx: Float, tx: Float, ky: Float, sy: Float, ty: Float): Long = error("intrinsic __skia_c_concat not installed")

// ImageBitmap: read one pixel as ARGB (0 when headless / out of range); blit a
// source surface onto a canvas surface (plain offset, or src-rect → dst-rect).
internal fun __skia_surf_pixel(handle: Long, x: Int, y: Int): Long = error("intrinsic __skia_surf_pixel not installed")
internal fun __skia_c_draw_surface(dst: Long, src: Long, x: Float, y: Float): Long = error("intrinsic __skia_c_draw_surface not installed")
internal fun __skia_c_draw_surface_rect(dst: Long, src: Long, sl: Float, st: Float, sr: Float, sb: Float, dl: Float, dt: Float, dr: Float, db: Float): Long = error("intrinsic __skia_c_draw_surface_rect not installed")

// Canvas.saveLayer: the draws up to the matching restore composite back through
// the layer's alpha, blend mode (skiaCode), the armed color filter and a blur of
// (blurX, blurY) sigma with the edge tile mode. hasBounds 0 covers the clip.
internal fun __skia_c_save_layer(handle: Long, l: Float, t: Float, r: Float, b: Float, hasBounds: Int, alpha: Float, blendMode: Int, blurX: Float, blurY: Float, tileMode: Int): Long = error("intrinsic __skia_c_save_layer not installed")

// Picture recording, for GraphicsLayer: begin returns a handle that draws like a
// surface's (0 headless); end frees it and returns the picture it drew, which
// draw_picture replays onto a canvas under its transform and clip.
internal fun __skia_rec_begin(width: Float, height: Float): Long = error("intrinsic __skia_rec_begin not installed")
internal fun __skia_rec_end(handle: Long): Long = error("intrinsic __skia_rec_end not installed")
internal fun __skia_picture_free(picture: Long): Long = error("intrinsic __skia_picture_free not installed")
internal fun __skia_c_draw_picture(handle: Long, picture: Long): Long = error("intrinsic __skia_c_draw_picture not installed")
