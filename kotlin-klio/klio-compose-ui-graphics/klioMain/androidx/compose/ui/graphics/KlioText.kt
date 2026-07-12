/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

// The klio Skia backend's text metrics + drawing, exposed to the ui-text pack,
// which implements the real androidx.compose.ui.text.Paragraph over these. All
// sizes and coordinates are in pixels. The bundled font is used for every run
// (klio's shim ignores per-typeface requests), so these take only text + size.

/** Advance width (px) of a single unwrapped run at [sizePx]. */
fun klioTextWidth(text: String, sizePx: Float): Float = __composeui_text_width(text, sizePx)

/** Font ascent (px, negative: above the baseline) at [sizePx]. */
fun klioFontAscent(sizePx: Float): Float = __composeui_font_metric(sizePx, 0)

/** Font descent (px, positive: below the baseline) at [sizePx]. */
fun klioFontDescent(sizePx: Float): Float = __composeui_font_metric(sizePx, 1)

/** Recommended extra line leading (px) at [sizePx]. */
fun klioFontLeading(sizePx: Float): Float = __composeui_font_metric(sizePx, 2)

/**
 * Draw a single text run with its baseline origin at ([x], [y]) onto [canvas],
 * honouring the canvas's current transform and clip. [argb] is packed as
 * 0xAARRGGBB. A no-op for a canvas that is not klio's Skia-backed one.
 */
fun klioDrawTextRun(canvas: Canvas, text: String, x: Float, y: Float, sizePx: Float, argb: Int) {
    val h = (canvas as? KlioCanvas)?.nativeHandle ?: return
    __skia_c_draw_text(h, text, x, y, sizePx, argb)
}

/**
 * Draw a STYLED text run: [flags] bit0 = synthetic bold, bit1 = synthetic
 * italic, bit2 = underline, bit3 = strikethrough. Advances match the plain
 * run (synthetic styles keep glyph metrics), so mixed-style lines lay out
 * with [klioTextWidth] measurements.
 */
fun klioDrawTextRun2(canvas: Canvas, text: String, x: Float, y: Float, sizePx: Float, argb: Int, flags: Int) {
    val h = (canvas as? KlioCanvas)?.nativeHandle ?: return
    __skia_c_draw_text2(h, text, x, y, sizePx, argb, flags)
}

/**
 * The Skia surface handle behind a klio [Canvas] (0 for any other canvas).
 * The ui-text pack's skparagraph engine paints onto this handle directly.
 */
fun klioCanvasHandle(canvas: Canvas): Long = (canvas as? KlioCanvas)?.nativeHandle ?: 0L
