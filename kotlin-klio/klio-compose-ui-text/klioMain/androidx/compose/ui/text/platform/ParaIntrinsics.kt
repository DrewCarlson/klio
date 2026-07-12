/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.text.platform

// Host intrinsics for the skparagraph text engine (src/compose_ui). A
// paragraph handle is an opaque Long; 0 means no Skia backend (callers fall
// back to the stub-metric layout). All indices are UTF-16 code units, so
// AnnotatedString offsets pass through unchanged.

internal fun __skia_para_new(textUtf8: String, spec: String): Long =
    error("intrinsic androidx.compose.ui.text.platform.__skia_para_new not installed")

internal fun __skia_para_layout(handle: Long, width: Float): Long =
    error("intrinsic __skia_para_layout not installed")

// which: 0 height, 1 maxIntrinsicWidth, 2 minIntrinsicWidth, 3 longestLine,
// 4 lineCount, 5 didExceedMaxLines, 6 alphabeticBaseline, 7 ideographicBaseline.
internal fun __skia_para_metric(handle: Long, which: Int): Float =
    error("intrinsic __skia_para_metric not installed")

// which: 0 top, 1 bottom, 2 baseline, 3 left, 4 width, 5 startU16,
// 6 endExcludingWhitespace, 7 endIncludingNewline, 8 end, 9 hardBreak.
internal fun __skia_para_line_metric(handle: Long, line: Int, which: Int): Float =
    error("intrinsic __skia_para_line_metric not installed")

internal fun __skia_para_offset_at(handle: Long, x: Float, y: Float): Int =
    error("intrinsic __skia_para_offset_at not installed")

// Union box of [start, end): which 0 l, 1 t, 2 r, 3 b, 4 box count.
internal fun __skia_para_box(handle: Long, start: Int, end: Int, which: Int): Float =
    error("intrinsic __skia_para_box not installed")

// The i-th selection box of [start, end): which 0 l, 1 t, 2 r, 3 b, 4 rtl.
internal fun __skia_para_range_rect(handle: Long, start: Int, end: Int, idx: Int, which: Int): Float =
    error("intrinsic __skia_para_range_rect not installed")

internal fun __skia_para_range_rect_count(handle: Long, start: Int, end: Int): Int =
    error("intrinsic __skia_para_range_rect_count not installed")

// Word containing `offset`, packed ((start shl 32) or end).
internal fun __skia_para_word(handle: Long, offset: Int): Long =
    error("intrinsic __skia_para_word not installed")

internal fun __skia_para_line_for(handle: Long, offset: Int): Int =
    error("intrinsic __skia_para_line_for not installed")

internal fun __skia_para_paint(handle: Long, surface: Long, x: Float, y: Float): Long =
    error("intrinsic __skia_para_paint not installed")

internal fun __skia_para_free(handle: Long): Long =
    error("intrinsic __skia_para_free not installed")

/** Register a font FILE's typeface under `family` in the paragraph provider. */
@Suppress("UNUSED_PARAMETER")
internal fun __skia_font_register(path: String, family: String): Boolean = false

/**
 * Load a font FILE (TTF/OTF) and register its typeface under [family] for
 * paragraph shaping. Returns true when a Skia backend is present and the
 * file loaded; false headless or on a bad path. `FontFamily(Font(path))`
 * does this implicitly with a path-derived family.
 */
fun klioRegisterFontFile(path: String, family: String): Boolean = __skia_font_register(path, family)
