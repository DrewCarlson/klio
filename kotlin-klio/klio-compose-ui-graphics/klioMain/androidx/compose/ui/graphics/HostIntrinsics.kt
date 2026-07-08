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
internal fun __skia_c_draw_rect(handle: Long, l: Float, t: Float, r: Float, b: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_rect not installed")
internal fun __skia_c_draw_rrect(handle: Long, l: Float, t: Float, r: Float, b: Float, rx: Float, ry: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_rrect not installed")
internal fun __skia_c_draw_oval(handle: Long, l: Float, t: Float, r: Float, b: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_oval not installed")
internal fun __skia_c_draw_circle(handle: Long, cx: Float, cy: Float, radius: Float, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_circle not installed")
internal fun __skia_c_draw_line(handle: Long, x0: Float, y0: Float, x1: Float, y1: Float, argb: Int, sw: Float, cap: Int, aa: Int): Long = error("intrinsic __skia_c_draw_line not installed")
internal fun __skia_c_draw_path(handle: Long, pathText: String, argb: Int, style: Int, sw: Float, cap: Int, join: Int, aa: Int): Long = error("intrinsic __skia_c_draw_path not installed")
