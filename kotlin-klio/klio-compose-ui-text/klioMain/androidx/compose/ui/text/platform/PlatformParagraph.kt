/*
 * Copyright 2020 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package androidx.compose.ui.text.platform

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.DrawStyle
import androidx.compose.ui.graphics.klioDrawTextRun
import androidx.compose.ui.graphics.klioFontAscent
import androidx.compose.ui.graphics.klioFontDescent
import androidx.compose.ui.graphics.klioFontLeading
import androidx.compose.ui.graphics.klioTextWidth
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Paragraph
import androidx.compose.ui.text.ParagraphIntrinsics
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

// Compose's default text size when a style leaves fontSize unspecified.
private val DefaultFontSize = 14.sp

private fun TextStyle.resolvedFontSizePx(density: Density): Float {
    val size = if (fontSize != TextUnit.Unspecified && fontSize.isSp) fontSize else DefaultFontSize
    return with(density) { size.toPx() }
}

private fun Color.toKlioArgb(): Int {
    val a = (alpha * 255f + 0.5f).toInt() and 0xFF
    val r = (red * 255f + 0.5f).toInt() and 0xFF
    val g = (green * 255f + 0.5f).toInt() and 0xFF
    val b = (blue * 255f + 0.5f).toInt() and 0xFF
    return (a shl 24) or (r shl 16) or (g shl 8) or b
}

/** One laid-out line: its text, char range in the source, and advance width. */
private class KlioLine(val text: String, val start: Int, val end: Int, val width: Float)

private fun splitKeepingSpaces(s: String): List<String> {
    val out = ArrayList<String>()
    val sb = StringBuilder()
    var i = 0
    while (i < s.length) {
        sb.append(s[i])
        if (s[i] == ' ') {
            while (i + 1 < s.length && s[i + 1] == ' ') { sb.append(s[i + 1]); i++ }
            out.add(sb.toString()); sb.setLength(0)
        }
        i++
    }
    if (sb.isNotEmpty()) out.add(sb.toString())
    return out
}

private fun longestWordWidth(text: String, sizePx: Float): Float {
    var max = 0f
    for (w in text.split(' ', '\n')) {
        val ww = klioTextWidth(w, sizePx)
        if (ww > max) max = ww
    }
    return max
}

/**
 * The klio [Paragraph]: wraps a single-style run to a width in pure Kotlin off the
 * shim's per-run width measurement, then paints each line via [klioDrawTextRun].
 * The shim draws with one bundled font, so layout is size-driven and left-to-right;
 * spans/placeholders/bidi are not modelled (klio renders one style per run).
 */
internal class KlioParagraph(
    val text: String,
    val style: TextStyle,
    val density: Density,
    val maxLines: Int,
    val ellipsis: Boolean,
    override val width: Float,
) : Paragraph {

    private val fontSizePx: Float = style.resolvedFontSizePx(density)
    private val ascent: Float = klioFontAscent(fontSizePx)   // negative
    private val descent: Float = klioFontDescent(fontSizePx) // positive
    private val leading: Float = klioFontLeading(fontSizePx)
    private val lineHeightPx: Float = (descent - ascent + leading).coerceAtLeast(fontSizePx)
    private val baselineFromTop: Float = -ascent

    private val allLines: List<KlioLine> = wrap()
    private val lines: List<KlioLine> =
        if (maxLines in 1 until allLines.size) allLines.subList(0, maxLines) else allLines

    override val height: Float get() = lineCount * lineHeightPx
    override val lineCount: Int get() = lines.size.coerceAtLeast(1)
    override val didExceedMaxLines: Boolean get() = allLines.size > lines.size
    override val firstBaseline: Float get() = baselineFromTop
    override val lastBaseline: Float get() = (lineCount - 1) * lineHeightPx + baselineFromTop

    override val minIntrinsicWidth: Float get() = longestWordWidth(text, fontSizePx)
    override val maxIntrinsicWidth: Float get() = klioTextWidth(text.replace('\n', ' '), fontSizePx)

    override val placeholderRects: List<Rect?> get() = emptyList()

    private fun wrap(): List<KlioLine> {
        val out = ArrayList<KlioLine>()
        var lineStart = 0
        val hardLines = text.split('\n')
        for (hard in hardLines) {
            when {
                hard.isEmpty() -> out.add(KlioLine("", lineStart, lineStart, 0f))
                width <= 0f || klioTextWidth(hard, fontSizePx) <= width ->
                    out.add(KlioLine(hard, lineStart, lineStart + hard.length, klioTextWidth(hard, fontSizePx)))
                else -> wrapHard(hard, lineStart, out)
            }
            lineStart += hard.length + 1 // + the consumed '\n'
        }
        return out
    }

    private fun wrapHard(s: String, base: Int, out: ArrayList<KlioLine>) {
        var cur = StringBuilder()
        var curStart = base
        var idx = base
        for (w in splitKeepingSpaces(s)) {
            val candidate = (cur.toString() + w).trimEnd()
            if (cur.isNotEmpty() && klioTextWidth(candidate, fontSizePx) > width) {
                val lineText = cur.toString().trimEnd()
                out.add(KlioLine(lineText, curStart, curStart + lineText.length, klioTextWidth(lineText, fontSizePx)))
                val trimmed = w.trimStart()
                cur = StringBuilder(trimmed)
                curStart = idx + (w.length - trimmed.length)
            } else {
                cur.append(w)
            }
            idx += w.length
        }
        if (cur.isNotEmpty()) {
            val lineText = cur.toString().trimEnd()
            out.add(KlioLine(lineText, curStart, curStart + lineText.length, klioTextWidth(lineText, fontSizePx)))
        }
    }

    private fun lineLeft(line: KlioLine): Float = when (style.textAlign) {
        TextAlign.Center -> ((width - line.width) / 2f).coerceAtLeast(0f)
        TextAlign.Right, TextAlign.End -> (width - line.width).coerceAtLeast(0f)
        else -> 0f
    }

    private fun clampLine(i: Int) = i.coerceIn(0, lineCount - 1)
    override fun getLineTop(lineIndex: Int): Float = clampLine(lineIndex) * lineHeightPx
    override fun getLineBottom(lineIndex: Int): Float = (clampLine(lineIndex) + 1) * lineHeightPx
    override fun getLineHeight(lineIndex: Int): Float = lineHeightPx
    override fun getLineBaseline(lineIndex: Int): Float = getLineTop(lineIndex) + baselineFromTop
    override fun getLineWidth(lineIndex: Int): Float = lines.getOrNull(lineIndex)?.width ?: 0f
    override fun getLineLeft(lineIndex: Int): Float = lines.getOrNull(lineIndex)?.let { lineLeft(it) } ?: 0f
    override fun getLineRight(lineIndex: Int): Float =
        lines.getOrNull(lineIndex)?.let { lineLeft(it) + it.width } ?: 0f
    override fun getLineStart(lineIndex: Int): Int = lines.getOrNull(lineIndex)?.start ?: 0
    override fun getLineEnd(lineIndex: Int, visibleEnd: Boolean): Int =
        lines.getOrNull(lineIndex)?.end ?: text.length
    override fun isLineEllipsized(lineIndex: Int): Boolean =
        ellipsis && didExceedMaxLines && lineIndex == lineCount - 1

    override fun getLineForOffset(offset: Int): Int {
        lines.forEachIndexed { i, l -> if (offset <= l.end) return i }
        return lineCount - 1
    }

    override fun getLineForVerticalPosition(vertical: Float): Int =
        (vertical / lineHeightPx).toInt().coerceIn(0, lineCount - 1)

    override fun getHorizontalPosition(offset: Int, usePrimaryDirection: Boolean): Float {
        val line = lines.getOrNull(getLineForOffset(offset)) ?: return 0f
        val within = (offset - line.start).coerceIn(0, line.text.length)
        return lineLeft(line) + klioTextWidth(line.text.substring(0, within), fontSizePx)
    }

    override fun getOffsetForPosition(position: Offset): Int {
        val line = lines.getOrNull(getLineForVerticalPosition(position.y)) ?: return 0
        val target = position.x - lineLeft(line)
        var i = 0
        while (i < line.text.length) {
            if (klioTextWidth(line.text.substring(0, i + 1), fontSizePx) > target) break
            i++
        }
        return line.start + i
    }

    override fun getParagraphDirection(offset: Int): ResolvedTextDirection = ResolvedTextDirection.Ltr
    override fun getBidiRunDirection(offset: Int): ResolvedTextDirection = ResolvedTextDirection.Ltr

    override fun getBoundingBox(offset: Int): Rect {
        val li = getLineForOffset(offset)
        val left = getHorizontalPosition(offset, true)
        val advance = lines.getOrNull(li)?.let {
            val within = (offset - it.start).coerceIn(0, it.text.length)
            if (within < it.text.length) klioTextWidth(it.text.substring(within, within + 1), fontSizePx) else 0f
        } ?: 0f
        return Rect(left, getLineTop(li), left + advance, getLineBottom(li))
    }

    override fun getCursorRect(offset: Int): Rect {
        val li = getLineForOffset(offset)
        val x = getHorizontalPosition(offset, true)
        return Rect(x, getLineTop(li), x, getLineBottom(li))
    }

    override fun getWordBoundary(offset: Int): TextRange {
        if (text.isEmpty()) return TextRange(0, 0)
        val o = offset.coerceIn(0, text.length)
        var s = o
        var e = o
        while (s > 0 && !text[s - 1].isWhitespace()) s--
        while (e < text.length && !text[e].isWhitespace()) e++
        return TextRange(s, e)
    }

    override fun getRangeForRect(
        rect: Rect,
        granularity: androidx.compose.ui.text.TextGranularity,
        inclusionStrategy: androidx.compose.ui.text.TextInclusionStrategy,
    ): TextRange = TextRange.Zero

    override fun getPathForRange(start: Int, end: Int): Path = Path()

    override fun fillBoundingBoxes(range: TextRange, array: FloatArray, arrayStart: Int) {
        var i = arrayStart
        var off = range.min
        while (off < range.max && i + 3 < array.size) {
            val b = getBoundingBox(off)
            array[i] = b.left; array[i + 1] = b.top; array[i + 2] = b.right; array[i + 3] = b.bottom
            i += 4; off++
        }
    }

    private fun paintLines(canvas: Canvas, argb: Int) {
        lines.forEachIndexed { i, line ->
            if (line.text.isNotEmpty()) {
                klioDrawTextRun(canvas, line.text, lineLeft(line), getLineBaseline(i), fontSizePx, argb)
            }
        }
    }

    private fun resolvedArgb(color: Color): Int {
        val c = color.takeOrElse { style.color }.takeOrElse { Color.Black }
        return c.toKlioArgb()
    }

    @Deprecated("Use the new paint function that takes canvas as the only required parameter.")
    override fun paint(canvas: Canvas, color: Color, shadow: Shadow?, textDecoration: TextDecoration?) {
        paintLines(canvas, resolvedArgb(color))
    }

    override fun paint(
        canvas: Canvas,
        color: Color,
        shadow: Shadow?,
        textDecoration: TextDecoration?,
        drawStyle: DrawStyle?,
        blendMode: BlendMode,
    ) {
        paintLines(canvas, resolvedArgb(color))
    }

    override fun paint(
        canvas: Canvas,
        brush: Brush,
        alpha: Float,
        shadow: Shadow?,
        textDecoration: TextDecoration?,
        drawStyle: DrawStyle?,
        blendMode: BlendMode,
    ) {
        val base = (brush as? SolidColor)?.value ?: style.color.takeOrElse { Color.Black }
        val a = if (alpha.isNaN()) base.alpha else (base.alpha * alpha).coerceIn(0f, 1f)
        paintLines(canvas, base.copy(alpha = a).toKlioArgb())
    }
}

/**
 * The klio [ParagraphIntrinsics]: carries the run so [ActualParagraph] can lay it
 * out at a width later, and reports intrinsic widths off the shim.
 */
internal class KlioParagraphIntrinsics(
    val text: String,
    val style: TextStyle,
    val density: Density,
) : ParagraphIntrinsics {
    private val fontSizePx = style.resolvedFontSizePx(density)
    override val minIntrinsicWidth: Float = longestWordWidth(text, fontSizePx)
    override val maxIntrinsicWidth: Float = klioTextWidth(text.replace('\n', ' '), fontSizePx)
    override val hasStaleResolvedFonts: Boolean = false
}

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
internal actual fun ActualParagraph(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    ellipsis: Boolean,
    width: Float,
    density: Density,
    resourceLoader: Font.ResourceLoader,
): Paragraph = KlioParagraph(text, style, density, maxLines, ellipsis, width)

internal actual fun ActualParagraph(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    overflow: TextOverflow,
    constraints: Constraints,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
): Paragraph = KlioParagraph(
    text, style, density, maxLines,
    ellipsis = overflow == TextOverflow.Ellipsis,
    width = constraints.maxWidth.toFloat(),
)

internal actual fun ActualParagraph(
    paragraphIntrinsics: ParagraphIntrinsics,
    maxLines: Int,
    overflow: TextOverflow,
    constraints: Constraints,
): Paragraph {
    val i = paragraphIntrinsics as KlioParagraphIntrinsics
    return KlioParagraph(
        i.text, i.style, i.density, maxLines,
        ellipsis = overflow == TextOverflow.Ellipsis,
        width = constraints.maxWidth.toFloat(),
    )
}

internal actual fun ActualParagraphIntrinsics(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
): ParagraphIntrinsics = KlioParagraphIntrinsics(text, style, density)
