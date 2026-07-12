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
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.klioCanvasHandle
import androidx.compose.ui.graphics.klioDrawTextRun
import androidx.compose.ui.graphics.klioDrawTextRun2
import androidx.compose.ui.graphics.klioFontAscent
import androidx.compose.ui.graphics.klioFontDescent
import androidx.compose.ui.graphics.klioFontLeading
import androidx.compose.ui.graphics.klioTextWidth
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.Paragraph
import androidx.compose.ui.text.ParagraphIntrinsics
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.TextGranularity
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontListFontFamily
import androidx.compose.ui.text.font.GenericFontFamily
import androidx.compose.ui.text.font.KlioFileFont
import androidx.compose.ui.text.style.ResolvedTextDirection
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextDirection
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

/** One fully-resolved styled run over [start, end) in UTF-16 units. */
private class KlioRun(
    val start: Int,
    val end: Int,
    val sizePx: Float,
    val weight: Int,
    val italic: Int,
    val deco: Int,
    val argb: Int,
    val family: String,
    val letterSpacingPx: Float,
)

// skparagraph TextDecoration bits.
private const val DECO_UNDERLINE = 1
private const val DECO_LINE_THROUGH = 4

private fun TextDecoration.skBits(): Int {
    var d = 0
    if (TextDecoration.Underline in this) d = d or DECO_UNDERLINE
    if (TextDecoration.LineThrough in this) d = d or DECO_LINE_THROUGH
    return d
}

/** A TextUnit in px for the spec: sp scales by density, em by the run's
 * font size; Unspecified (or a non-positive value) contributes 0. */
private fun TextUnit.klioPx(density: Density, fontSizePx: Float): Float = when {
    this == TextUnit.Unspecified -> 0f
    isSp -> with(density) { toPx() }
    isEm -> value * fontSizePx
    else -> 0f
}

// skparagraph PlaceholderAlignment: baseline 0, aboveBaseline 1,
// belowBaseline 2, top 3, bottom 4, middle 5 (the spec's `h` field).
private fun PlaceholderVerticalAlign.skPhAlign(): Int = when (this) {
    PlaceholderVerticalAlign.AboveBaseline -> 1
    PlaceholderVerticalAlign.Top -> 3
    PlaceholderVerticalAlign.Bottom -> 4
    PlaceholderVerticalAlign.Center -> 5
    PlaceholderVerticalAlign.TextTop -> 3
    PlaceholderVerticalAlign.TextBottom -> 4
    PlaceholderVerticalAlign.TextCenter -> 5
    else -> 0
}

private fun FontFamily?.klioName(): String = when (this) {
    is GenericFontFamily -> name
    // A file-backed font list: register the first file font (once) and
    // shape with its path-derived family alias.
    is FontListFontFamily -> {
        val ff = fonts.firstOrNull { it is KlioFileFont } as? KlioFileFont
        if (ff != null) KlioFileFont.aliasFor(ff) else "-"
    }
    else -> "-"
}

// skparagraph TextAlign: left 0, right 1, center 2, justify 3, start 4, end 5.
private fun TextAlign?.skAlign(): Int = when (this) {
    TextAlign.Left -> 0
    TextAlign.Right -> 1
    TextAlign.Center -> 2
    TextAlign.Justify -> 3
    TextAlign.End -> 5
    else -> 4
}

/**
 * The klio [Paragraph]. With a Skia backend it is a real skparagraph layout:
 * the AnnotatedString's SpanStyles become styled runs (per-span size, weight,
 * style, decoration, color, family) shaped and wrapped by skia::textlayout,
 * with UTF-16 offsets flowing through unchanged — metrics, hit testing, word
 * boundaries, and selection boxes all answer from the real layout. Headless
 * (no backend) it falls back to a deterministic stub layout: a pure-Kotlin
 * greedy wrap over the shim's (zeroed) width metrics, so programs keep
 * running with stable output.
 */
internal class KlioParagraph(
    val text: String,
    val style: TextStyle,
    val density: Density,
    val maxLines: Int,
    val ellipsis: Boolean,
    override val width: Float,
    val annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>> = emptyList(),
    val placeholders: List<AnnotatedString.Range<Placeholder>> = emptyList(),
) : Paragraph {

    // The SpanStyle ranges, in application order (a later span overrides the
    // attributes it sets on the overlap).
    private val spanRanges: List<AnnotatedString.Range<SpanStyle>> = run {
        val out = ArrayList<AnnotatedString.Range<SpanStyle>>()
        for (r in annotations) {
            val item = r.item
            if (item is SpanStyle) out.add(AnnotatedString.Range(item, r.start, r.end))
        }
        out
    }

    private val fontSizePx: Float = style.resolvedFontSizePx(density)
    private val baseWeight: Int = style.fontWeight?.weight ?: 400
    private val baseItalic: Int = if (style.fontStyle == FontStyle.Italic) 1 else 0
    private val baseDeco: Int = style.textDecoration?.skBits() ?: 0
    private val baseLetterSpacingPx: Float = style.letterSpacing.klioPx(density, fontSizePx)
    private val paraLineHeightPx: Float = style.lineHeight.klioPx(density, fontSizePx)
    private fun baseArgb(): Int = style.color.takeOrElse { Color.Black }.toKlioArgb()

    // ---- resolved runs (shared by the native spec and styled stub paint) ----

    private fun resolvedRuns(baseColor: Int, decoOverride: TextDecoration?): List<KlioRun> {
        val overrideDeco = decoOverride?.skBits()
        if (spanRanges.isEmpty()) {
            val d = overrideDeco ?: baseDeco
            if (d == 0 && baseWeight < 600 && baseItalic == 0) return emptyList()
            return listOf(KlioRun(0, text.length, fontSizePx, baseWeight, baseItalic, d, baseColor, style.fontFamily.klioName(), baseLetterSpacingPx))
        }
        val out = ArrayList<KlioRun>()
        var seg = 0
        while (seg < text.length) {
            var end = text.length
            for (r in spanRanges) {
                if (r.start in (seg + 1) until end) end = r.start
                if (r.end in (seg + 1) until end) end = r.end
            }
            var size = fontSizePx
            var weight = baseWeight
            var italic = baseItalic
            var deco = overrideDeco ?: baseDeco
            var argb = baseColor
            var family = style.fontFamily.klioName()
            var letterSp = baseLetterSpacingPx
            for (r in spanRanges) {
                if (seg >= r.start && seg < r.end) {
                    val st = r.item
                    if (st.color.isSpecified) argb = st.color.toKlioArgb()
                    if (st.fontSize != TextUnit.Unspecified && st.fontSize.isSp) {
                        size = with(density) { st.fontSize.toPx() }
                    }
                    st.fontWeight?.let { weight = it.weight }
                    st.fontStyle?.let { italic = if (it == FontStyle.Italic) 1 else 0 }
                    st.textDecoration?.let { deco = it.skBits() }
                    st.fontFamily?.let { family = it.klioName() }
                    if (st.letterSpacing != TextUnit.Unspecified) {
                        letterSp = st.letterSpacing.klioPx(density, size)
                    }
                }
            }
            out.add(KlioRun(seg, end, size, weight, italic, deco, argb, family, letterSp))
            seg = end
        }
        return out
    }

    private fun buildSpec(baseColor: Int, decoOverride: TextDecoration?): String {
        val sb = StringBuilder()
        val dir = if (style.textDirection == TextDirection.Rtl) 1 else 0
        sb.append("p ").append(fontSizePx).append(' ').append(style.textAlign.skAlign()).append(' ')
            .append(if (maxLines == Int.MAX_VALUE) 0 else maxLines).append(' ')
            .append(if (ellipsis) 1 else 0).append(' ').append(dir).append(' ')
            .append(baseWeight).append(' ').append(baseItalic).append(' ')
            .append(decoOverride?.skBits() ?: baseDeco).append(' ')
            .append(baseColor.toLong() and 0xFFFFFFFFL).append(' ')
            .append(baseLetterSpacingPx).append(' ').append(paraLineHeightPx).append('\n')
        for (r in resolvedRuns(baseColor, decoOverride)) {
            sb.append("r ").append(r.start).append(' ').append(r.end).append(' ')
                .append(r.sizePx).append(' ').append(r.weight).append(' ').append(r.italic).append(' ')
                .append(r.deco).append(' ').append(r.argb.toLong() and 0xFFFFFFFFL).append(' ')
                .append(r.family).append(' ')
                .append(r.letterSpacingPx).append(' ').append(paraLineHeightPx).append('\n')
        }
        for (ph in placeholders) {
            val w = ph.item.width.klioPx(density, fontSizePx)
            val h = ph.item.height.klioPx(density, fontSizePx)
            if (w <= 0f || h <= 0f) continue
            sb.append("h ").append(ph.start).append(' ').append(ph.end).append(' ')
                .append(w).append(' ').append(h).append(' ')
                .append(ph.item.placeholderVerticalAlign.skPhAlign()).append('\n')
        }
        return sb.toString()
    }

    // ---- native skparagraph layout ----

    private var nativeBaseArgb: Int = baseArgb()
    private var nativeDeco: TextDecoration? = null
    private var native: Long = run {
        val h = __skia_para_new(text, buildSpec(nativeBaseArgb, null))
        if (h != 0L) __skia_para_layout(h, if (width > 0f) width else Float.MAX_VALUE)
        h
    }

    /** True when this paragraph shaped through skparagraph at construction.
     * The mode never changes afterwards: an EVICTED native paragraph revives
     * through [nh], it never falls back to the headless stub (whose layout
     * fields are only computed for stub-mode paragraphs). */
    private val isNative: Boolean = native != 0L

    init {
        if (isNative) registryAdd(this)
    }

    /** The live native handle, reviving an evicted paragraph. Every
     * intrinsic call goes through this accessor. */
    private fun nh(): Long {
        if (isNative && native == 0L) {
            native = __skia_para_new(text, buildSpec(nativeBaseArgb, nativeDeco))
            if (native != 0L) __skia_para_layout(native, if (width > 0f) width else Float.MAX_VALUE)
            registryAdd(this)
        }
        return native
    }

    private fun nativeRebuild(baseColor: Int, decoOverride: TextDecoration?) {
        if (native != 0L) __skia_para_free(native) else if (isNative) registryAdd(this)
        native = __skia_para_new(text, buildSpec(baseColor, decoOverride))
        if (native != 0L) __skia_para_layout(native, if (width > 0f) width else Float.MAX_VALUE)
        nativeBaseArgb = baseColor
        nativeDeco = decoOverride
    }

    /** Registry eviction callback: free the handle; [nh] revives on demand. */
    internal fun evictNative() {
        if (native != 0L) {
            __skia_para_free(native)
            native = 0L
        }
    }

    private fun metric(which: Int): Float = __skia_para_metric(nh(), which)
    private fun lineMetric(line: Int, which: Int): Float = __skia_para_line_metric(nh(), line, which)

    internal companion object {
        // Bounded pool of live skparagraph handles: compose caches layouts,
        // but a scrolling LazyColumn churns paragraphs without ever
        // disposing them. Oldest-first eviction; an evicted paragraph
        // re-shapes on next use.
        private const val MAX_LIVE = 192
        private val live = ArrayDeque<KlioParagraph>()

        private fun registryAdd(p: KlioParagraph) {
            live.addLast(p)
            while (live.size > MAX_LIVE) {
                live.removeFirst().evictNative()
            }
        }
    }

    // ---- stub layout (headless fallback; only computed when native == 0) ----

    private val ascent: Float = if (isNative) 0f else klioFontAscent(fontSizePx)   // negative
    private val descent: Float = if (isNative) 0f else klioFontDescent(fontSizePx) // positive
    private val leading: Float = if (isNative) 0f else klioFontLeading(fontSizePx)
    private val lineHeightPx: Float =
        if (isNative) 0f else (descent - ascent + leading).coerceAtLeast(fontSizePx)
    private val baselineFromTop: Float = -ascent

    private val allLines: List<KlioLine> = if (isNative) emptyList() else wrap()
    private val lines: List<KlioLine> =
        if (maxLines in 1 until allLines.size) allLines.subList(0, maxLines) else allLines

    override val height: Float
        get() = if (isNative) metric(0) else lineCount * lineHeightPx
    override val lineCount: Int
        get() = if (isNative) metric(4).toInt().coerceAtLeast(1) else lines.size.coerceAtLeast(1)
    override val didExceedMaxLines: Boolean
        get() = if (isNative) metric(5) != 0f else allLines.size > lines.size
    override val firstBaseline: Float
        get() = if (isNative) lineMetric(0, 2) else baselineFromTop
    override val lastBaseline: Float
        get() = if (isNative) lineMetric(lineCount - 1, 2)
        else (lineCount - 1) * lineHeightPx + baselineFromTop

    override val minIntrinsicWidth: Float
        get() = if (isNative) metric(2) else longestWordWidth(text, fontSizePx)
    override val maxIntrinsicWidth: Float
        get() = if (isNative) metric(1) else klioTextWidth(text.replace('\n', ' '), fontSizePx)

    override val placeholderRects: List<Rect?>
        get() {
            if (!isNative || placeholders.isEmpty()) return placeholders.map { null }
            val n = __skia_para_ph_count(nh())
            val out = ArrayList<Rect?>(placeholders.size)
            var i = 0
            while (i < placeholders.size) {
                if (i < n) {
                    out.add(
                        Rect(
                            __skia_para_ph_rect(nh(), i, 0),
                            __skia_para_ph_rect(nh(), i, 1),
                            __skia_para_ph_rect(nh(), i, 2),
                            __skia_para_ph_rect(nh(), i, 3),
                        )
                    )
                } else {
                    out.add(null)
                }
                i++
            }
            return out
        }

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

    override fun getLineTop(lineIndex: Int): Float =
        if (isNative) lineMetric(clampLine(lineIndex), 0) else clampLine(lineIndex) * lineHeightPx

    override fun getLineBottom(lineIndex: Int): Float =
        if (isNative) lineMetric(clampLine(lineIndex), 1) else (clampLine(lineIndex) + 1) * lineHeightPx

    override fun getLineHeight(lineIndex: Int): Float =
        if (isNative) getLineBottom(lineIndex) - getLineTop(lineIndex) else lineHeightPx

    override fun getLineBaseline(lineIndex: Int): Float =
        if (isNative) lineMetric(clampLine(lineIndex), 2) else getLineTop(lineIndex) + baselineFromTop

    override fun getLineWidth(lineIndex: Int): Float =
        if (isNative) lineMetric(clampLine(lineIndex), 4) else lines.getOrNull(lineIndex)?.width ?: 0f

    override fun getLineLeft(lineIndex: Int): Float =
        if (isNative) lineMetric(clampLine(lineIndex), 3)
        else lines.getOrNull(lineIndex)?.let { lineLeft(it) } ?: 0f

    override fun getLineRight(lineIndex: Int): Float =
        if (isNative) getLineLeft(lineIndex) + getLineWidth(lineIndex)
        else lines.getOrNull(lineIndex)?.let { lineLeft(it) + it.width } ?: 0f

    override fun getLineStart(lineIndex: Int): Int =
        if (isNative) lineMetric(clampLine(lineIndex), 5).toInt()
        else lines.getOrNull(lineIndex)?.start ?: 0

    override fun getLineEnd(lineIndex: Int, visibleEnd: Boolean): Int =
        if (isNative) lineMetric(clampLine(lineIndex), if (visibleEnd) 6 else 8).toInt()
        else lines.getOrNull(lineIndex)?.end ?: text.length

    override fun isLineEllipsized(lineIndex: Int): Boolean =
        ellipsis && didExceedMaxLines && lineIndex == lineCount - 1

    override fun getLineForOffset(offset: Int): Int {
        if (isNative) return __skia_para_line_for(nh(), offset.coerceIn(0, text.length)).coerceIn(0, lineCount - 1)
        lines.forEachIndexed { i, l -> if (offset <= l.end) return i }
        return lineCount - 1
    }

    override fun getLineForVerticalPosition(vertical: Float): Int {
        if (isNative) {
            var i = 0
            val n = lineCount
            while (i < n) {
                if (vertical < lineMetric(i, 1)) return i
                i++
            }
            return n - 1
        }
        return (vertical / lineHeightPx).toInt().coerceIn(0, lineCount - 1)
    }

    override fun getHorizontalPosition(offset: Int, usePrimaryDirection: Boolean): Float {
        if (isNative) {
            val o = offset.coerceIn(0, text.length)
            if (o < text.length) {
                if (__skia_para_box(nh(), o, o + 1, 4) > 0f) return __skia_para_box(nh(), o, o + 1, 0)
            }
            if (o > 0 && __skia_para_box(nh(), o - 1, o, 4) > 0f) return __skia_para_box(nh(), o - 1, o, 2)
            return getLineLeft(getLineForOffset(o))
        }
        val line = lines.getOrNull(getLineForOffset(offset)) ?: return 0f
        val within = (offset - line.start).coerceIn(0, line.text.length)
        return lineLeft(line) + klioTextWidth(line.text.substring(0, within), fontSizePx)
    }

    override fun getOffsetForPosition(position: Offset): Int {
        if (isNative) return __skia_para_offset_at(nh(), position.x, position.y).coerceIn(0, text.length)
        val line = lines.getOrNull(getLineForVerticalPosition(position.y)) ?: return 0
        val target = position.x - lineLeft(line)
        var i = 0
        while (i < line.text.length) {
            if (klioTextWidth(line.text.substring(0, i + 1), fontSizePx) > target) break
            i++
        }
        return line.start + i
    }

    override fun getParagraphDirection(offset: Int): ResolvedTextDirection =
        if (style.textDirection == TextDirection.Rtl) ResolvedTextDirection.Rtl else ResolvedTextDirection.Ltr

    override fun getBidiRunDirection(offset: Int): ResolvedTextDirection {
        if (isNative && offset < text.length) {
            val rtl = __skia_para_range_rect(nh(), offset, offset + 1, 0, 4)
            return if (rtl != 0f) ResolvedTextDirection.Rtl else ResolvedTextDirection.Ltr
        }
        return getParagraphDirection(offset)
    }

    override fun getBoundingBox(offset: Int): Rect {
        if (isNative) {
            val o = offset.coerceIn(0, if (text.isEmpty()) 0 else text.length - 1)
            if (text.isNotEmpty() && __skia_para_box(nh(), o, o + 1, 4) > 0f) {
                return Rect(
                    __skia_para_box(nh(), o, o + 1, 0),
                    __skia_para_box(nh(), o, o + 1, 1),
                    __skia_para_box(nh(), o, o + 1, 2),
                    __skia_para_box(nh(), o, o + 1, 3),
                )
            }
            val li = getLineForOffset(offset)
            val x = getHorizontalPosition(offset, true)
            return Rect(x, getLineTop(li), x, getLineBottom(li))
        }
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
        if (isNative) {
            val packed = __skia_para_word(nh(), offset.coerceIn(0, text.length - 1))
            val s = (packed ushr 32).toInt()
            val e = (packed and 0xFFFFFFFFL).toInt()
            if (e in (s + 1)..text.length) return TextRange(s, e)
        }
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
    ): TextRange {
        if (rect.isEmpty) return TextRange.Zero
        // Corner hit-tests bound the covered offsets; Word granularity
        // snaps both ends to their word boundaries. The inclusion
        // strategy's finer partial-glyph decisions collapse to the
        // corner-derived range (anything the rect touches is included).
        val startOff = getOffsetForPosition(Offset(rect.left, rect.top))
        val endOff = getOffsetForPosition(Offset(rect.right, rect.bottom))
        if (endOff <= startOff) return TextRange.Zero
        var s = startOff
        var e = endOff
        if (granularity == TextGranularity.Word) {
            val ws = getWordBoundary(s)
            val we = getWordBoundary(if (e > 0) e - 1 else e)
            s = minOf(ws.start, s)
            e = maxOf(we.end, e)
        }
        return TextRange(s.coerceIn(0, text.length), e.coerceIn(0, text.length))
    }

    override fun getPathForRange(start: Int, end: Int): Path {
        val p = Path()
        if (isNative && end > start) {
            val n = __skia_para_range_rect_count(nh(), start, end)
            var i = 0
            while (i < n) {
                p.addRect(
                    Rect(
                        __skia_para_range_rect(nh(), start, end, i, 0),
                        __skia_para_range_rect(nh(), start, end, i, 1),
                        __skia_para_range_rect(nh(), start, end, i, 2),
                        __skia_para_range_rect(nh(), start, end, i, 3),
                    )
                )
                i++
            }
        }
        return p
    }

    override fun fillBoundingBoxes(range: TextRange, array: FloatArray, arrayStart: Int) {
        var i = arrayStart
        var off = range.min
        while (off < range.max && i + 3 < array.size) {
            val b = getBoundingBox(off)
            array[i] = b.left; array[i + 1] = b.top; array[i + 2] = b.right; array[i + 3] = b.bottom
            i += 4; off++
        }
    }

    // ---- painting ----

    // Paragraph-level style flags for the stub painter.
    private fun baseFlags(deco: TextDecoration?): Int {
        var f = 0
        if (baseWeight >= 600) f = f or 1
        if (baseItalic != 0) f = f or 2
        val d = deco ?: style.textDecoration
        if (d != null) {
            if (TextDecoration.Underline in d) f = f or 4
            if (TextDecoration.LineThrough in d) f = f or 8
        }
        return f
    }

    private fun nativePaint(canvas: Canvas, argb: Int, deco: TextDecoration?) {
        if (argb != nativeBaseArgb || deco != nativeDeco) nativeRebuild(argb, deco)
        val surf = klioCanvasHandle(canvas)
        if (surf != 0L && isNative) __skia_para_paint(nh(), surf, 0f, 0f)
    }

    private fun paintLines(canvas: Canvas, argb: Int, deco: TextDecoration? = null) {
        if (isNative) {
            nativePaint(canvas, argb, deco)
            return
        }
        val bf = baseFlags(deco)
        lines.forEachIndexed { i, line ->
            if (line.text.isEmpty()) return@forEachIndexed
            val baseline = getLineBaseline(i)
            if (spanRanges.isEmpty() && bf == 0) {
                klioDrawTextRun(canvas, line.text, lineLeft(line), baseline, fontSizePx, argb)
                return@forEachIndexed
            }
            var x = lineLeft(line)
            for (r in resolvedRuns(argb, deco)) {
                val s = maxOf(r.start, line.start)
                val e = minOf(r.end, line.end)
                if (e <= s) continue
                val runText = line.text.substring(s - line.start, e - line.start)
                if (runText.isNotEmpty()) {
                    var f = 0
                    if (r.weight >= 600) f = f or 1
                    if (r.italic != 0) f = f or 2
                    if (r.deco and DECO_UNDERLINE != 0) f = f or 4
                    if (r.deco and DECO_LINE_THROUGH != 0) f = f or 8
                    klioDrawTextRun2(canvas, runText, x, baseline, fontSizePx, r.argb, f)
                    x += klioTextWidth(runText, fontSizePx)
                }
            }
        }
    }

    private fun resolvedArgb(color: Color): Int {
        val c = color.takeOrElse { style.color }.takeOrElse { Color.Black }
        return c.toKlioArgb()
    }

    @Deprecated("Use the new paint function that takes canvas as the only required parameter.")
    override fun paint(canvas: Canvas, color: Color, shadow: Shadow?, textDecoration: TextDecoration?) {
        paintLines(canvas, resolvedArgb(color), textDecoration)
    }

    override fun paint(
        canvas: Canvas,
        color: Color,
        shadow: Shadow?,
        textDecoration: TextDecoration?,
        drawStyle: DrawStyle?,
        blendMode: BlendMode,
    ) {
        paintLines(canvas, resolvedArgb(color), textDecoration)
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
        paintLines(canvas, base.copy(alpha = a).toKlioArgb(), textDecoration)
    }
}

/**
 * The klio [ParagraphIntrinsics]: carries the run so [ActualParagraph] can lay it
 * out at a width later. With a Skia backend the intrinsic widths come from a
 * real skparagraph layout at unbounded width; headless from the stub metrics.
 */
internal class KlioParagraphIntrinsics(
    val text: String,
    val style: TextStyle,
    val density: Density,
    val annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>> = emptyList(),
    val placeholders: List<AnnotatedString.Range<Placeholder>> = emptyList(),
) : ParagraphIntrinsics {
    private val measured = KlioParagraph(text, style, density, maxLines = 0, ellipsis = false, width = 0f, annotations = annotations, placeholders = placeholders)
    override val minIntrinsicWidth: Float = measured.minIntrinsicWidth
    override val maxIntrinsicWidth: Float = measured.maxIntrinsicWidth
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
): Paragraph = KlioParagraph(text, style, density, maxLines, ellipsis, width, annotations, placeholders)

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
    annotations = annotations,
    placeholders = placeholders,
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
        annotations = i.annotations,
        placeholders = i.placeholders,
    )
}

internal actual fun ActualParagraphIntrinsics(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
): ParagraphIntrinsics = KlioParagraphIntrinsics(text, style, density, annotations, placeholders)
