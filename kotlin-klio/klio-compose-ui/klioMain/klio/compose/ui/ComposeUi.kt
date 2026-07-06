// A minimal Compose UI core on a headless software canvas — the first increment
// of the Compose-UI stack. A @Composable tree emits LayoutNodes through the
// compose runtime's node path (ComposeNode -> LayoutNodeApplier); a measure pass
// sizes and places them under Constraints, and a draw pass paints backgrounds
// into a software pixel buffer that dumps deterministically as ASCII. This proves
// the LayoutNode + measure/layout/draw + software-canvas architecture runs on
// klio end-to-end; native Skia, windowing, text/font rendering, and the full
// foundation/material surface are deferred.

package klio.compose.ui

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.key

// ----- color -----

/** An ARGB color. The pixel dump maps each to a distinct character. */
class Color(val argb: Int) {
    companion object {
        val Transparent = Color(0)
        val Black = Color(1)
        val White = Color(2)
        val Red = Color(3)
        val Green = Color(4)
        val Blue = Color(5)
        val Yellow = Color(6)
        val Cyan = Color(7)
        val Magenta = Color(8)
        val Gray = Color(9)
    }
}

private fun charFor(argb: Int): Char {
    return when (argb) {
        0 -> '.'
        1 -> 'K'
        2 -> 'W'
        3 -> 'R'
        4 -> 'G'
        5 -> 'B'
        6 -> 'Y'
        7 -> 'C'
        8 -> 'M'
        9 -> 'g'
        else -> '?'
    }
}

// ----- bitmap font (3x5 glyphs) -----

// Each glyph is 5 rows of 3 columns, packed as 3 low bits per row (bit 2 = left).
private fun glyph(c: Char): IntArray {
    return when (c) {
        '0' -> intArrayOf(7, 5, 5, 5, 7)
        '1' -> intArrayOf(2, 6, 2, 2, 7)
        '2' -> intArrayOf(7, 1, 7, 4, 7)
        '3' -> intArrayOf(7, 1, 7, 1, 7)
        '4' -> intArrayOf(5, 5, 7, 1, 1)
        '5' -> intArrayOf(7, 4, 7, 1, 7)
        '6' -> intArrayOf(7, 4, 7, 5, 7)
        '7' -> intArrayOf(7, 1, 2, 2, 2)
        '8' -> intArrayOf(7, 5, 7, 5, 7)
        '9' -> intArrayOf(7, 5, 7, 1, 7)
        'A' -> intArrayOf(2, 5, 7, 5, 5)
        'C' -> intArrayOf(7, 4, 4, 4, 7)
        'E' -> intArrayOf(7, 4, 7, 4, 7)
        'H' -> intArrayOf(5, 5, 7, 5, 5)
        'I' -> intArrayOf(7, 2, 2, 2, 7)
        'K' -> intArrayOf(5, 5, 6, 5, 5)
        'L' -> intArrayOf(4, 4, 4, 4, 7)
        'N' -> intArrayOf(5, 7, 7, 7, 5)
        'O' -> intArrayOf(7, 5, 5, 5, 7)
        'R' -> intArrayOf(7, 5, 7, 6, 5)
        'T' -> intArrayOf(7, 2, 2, 2, 2)
        'U' -> intArrayOf(5, 5, 5, 5, 7)
        'Y' -> intArrayOf(5, 5, 2, 2, 2)
        ' ' -> intArrayOf(0, 0, 0, 0, 0)
        else -> intArrayOf(7, 5, 5, 5, 7) // unknown → filled box outline
    }
}

private const val GLYPH_W = 3
private const val GLYPH_H = 5
private const val GLYPH_ADVANCE = 4 // 3px glyph + 1px gap

// ----- geometry -----

/** Measurement bounds handed down the tree during the measure pass. */
class Constraints(val minWidth: Int, val maxWidth: Int, val minHeight: Int, val maxHeight: Int)

private fun clamp(value: Int, lo: Int, hi: Int): Int {
    if (value < lo) return lo
    if (value > hi) return hi
    return value
}

// ----- software canvas -----

/** A software pixel buffer; the draw pass fills rectangles into it. */
class PixelCanvas(val width: Int, val height: Int) {
    val pixels = IntArray(width * height)

    fun fillRect(x: Int, y: Int, w: Int, h: Int, argb: Int) {
        var yy = y
        val yEnd = y + h
        while (yy < yEnd && yy < height) {
            if (yy >= 0) {
                var xx = x
                val xEnd = x + w
                while (xx < xEnd && xx < width) {
                    if (xx >= 0) pixels[yy * width + xx] = argb
                    xx += 1
                }
            }
            yy += 1
        }
    }

    fun toAscii(): String {
        val sb = StringBuilder()
        var row = 0
        while (row < height) {
            var col = 0
            while (col < width) {
                sb.append(charFor(pixels[row * width + col]))
                col += 1
            }
            if (row < height - 1) sb.append('\n')
            row += 1
        }
        return sb.toString()
    }
}

// ----- modifier -----

/**
 * A layout/draw modifier. Real Compose folds a chain of Modifier.Node; this
 * captures the same intent as resolved fields (size, padding, background, fill).
 */
class Modifier private constructor(
    val width: Int,
    val height: Int,
    val padding: Int,
    val background: Color?,
    val fillMaxWidth: Boolean,
    val fillMaxHeight: Boolean,
    val onClick: (() -> Unit)?,
) {
    private fun copy(
        width: Int = this.width,
        height: Int = this.height,
        padding: Int = this.padding,
        background: Color? = this.background,
        fillMaxWidth: Boolean = this.fillMaxWidth,
        fillMaxHeight: Boolean = this.fillMaxHeight,
        onClick: (() -> Unit)? = this.onClick,
    ): Modifier = Modifier(width, height, padding, background, fillMaxWidth, fillMaxHeight, onClick)

    fun size(w: Int, h: Int): Modifier = copy(width = w, height = h)
    fun width(w: Int): Modifier = copy(width = w)
    fun height(h: Int): Modifier = copy(height = h)
    fun padding(p: Int): Modifier = copy(padding = p)
    fun background(c: Color): Modifier = copy(background = c)
    fun fillMaxWidth(): Modifier = copy(fillMaxWidth = true)
    fun fillMaxHeight(): Modifier = copy(fillMaxHeight = true)
    fun fillMaxSize(): Modifier = copy(fillMaxWidth = true, fillMaxHeight = true)
    fun clickable(onClick: () -> Unit): Modifier = copy(onClick = onClick)

    companion object {
        val None = Modifier(-1, -1, 0, null, false, false, null)
    }
}

// ----- layout node + applier -----

/** The layout node — the applier's node type. Measures + places its children
 * per its [arrangement], then draws its background and children. */
class LayoutNode {
    var modifier: Modifier = Modifier.None
    var arrangement: String = "Box" // Box (stack), Row (horizontal), Column (vertical)
    val children = mutableListOf<LayoutNode>()
    var measuredWidth = 0
    var measuredHeight = 0
    var offsetX = 0
    var offsetY = 0
    var text: String = ""
    var textColor: Color? = null

    fun measure(constraints: Constraints) {
        val pad = modifier.padding
        val ownMaxW = if (modifier.fillMaxWidth) constraints.maxWidth
            else if (modifier.width >= 0) modifier.width else constraints.maxWidth
        val ownMaxH = if (modifier.fillMaxHeight) constraints.maxHeight
            else if (modifier.height >= 0) modifier.height else constraints.maxHeight
        val childMaxW = if (ownMaxW - 2 * pad > 0) ownMaxW - 2 * pad else 0
        val childMaxH = if (ownMaxH - 2 * pad > 0) ownMaxH - 2 * pad else 0
        val childConstraints = Constraints(0, childMaxW, 0, childMaxH)

        var contentW = 0
        var contentH = 0
        if (text.isNotEmpty()) {
            contentW = text.length * GLYPH_ADVANCE - 1
            contentH = GLYPH_H
        }
        if (arrangement == "Row") {
            var cursor = 0
            for (child in children) {
                child.measure(childConstraints)
                child.offsetX = pad + cursor
                child.offsetY = pad
                cursor += child.measuredWidth
                if (child.measuredHeight > contentH) contentH = child.measuredHeight
            }
            contentW = cursor
        } else if (arrangement == "Column") {
            var cursor = 0
            for (child in children) {
                child.measure(childConstraints)
                child.offsetX = pad
                child.offsetY = pad + cursor
                cursor += child.measuredHeight
                if (child.measuredWidth > contentW) contentW = child.measuredWidth
            }
            contentH = cursor
        } else {
            for (child in children) {
                child.measure(childConstraints)
                child.offsetX = pad
                child.offsetY = pad
                if (child.measuredWidth > contentW) contentW = child.measuredWidth
                if (child.measuredHeight > contentH) contentH = child.measuredHeight
            }
        }

        val wantW = if (modifier.fillMaxWidth) constraints.maxWidth
            else if (modifier.width >= 0) modifier.width else contentW + 2 * pad
        val wantH = if (modifier.fillMaxHeight) constraints.maxHeight
            else if (modifier.height >= 0) modifier.height else contentH + 2 * pad
        measuredWidth = clamp(wantW, constraints.minWidth, constraints.maxWidth)
        measuredHeight = clamp(wantH, constraints.minHeight, constraints.maxHeight)
    }

    fun draw(canvas: PixelCanvas, originX: Int, originY: Int, hits: MutableList<HitRegion>) {
        val bg = modifier.background
        if (bg != null) canvas.fillRect(originX, originY, measuredWidth, measuredHeight, bg.argb)
        val onClick = modifier.onClick
        if (onClick != null) {
            hits.add(HitRegion(originX, originY, measuredWidth, measuredHeight, onClick))
        }
        val pad = modifier.padding
        if (text.isNotEmpty()) {
            val fg = textColor ?: Color.White
            var penX = originX + pad
            var i = 0
            while (i < text.length) {
                val rows = glyph(text[i])
                var gy = 0
                while (gy < GLYPH_H) {
                    val bits = rows[gy]
                    var gx = 0
                    while (gx < GLYPH_W) {
                        val on = (bits shr (GLYPH_W - 1 - gx)) and 1
                        if (on != 0) canvas.fillRect(penX + gx, originY + pad + gy, 1, 1, fg.argb)
                        gx += 1
                    }
                    gy += 1
                }
                penX += GLYPH_ADVANCE
                i += 1
            }
        }
        for (child in children) {
            child.draw(canvas, originX + child.offsetX, originY + child.offsetY, hits)
        }
    }
}

/** A clickable region collected during the draw pass (absolute bounds + handler). */
class HitRegion(val x: Int, val y: Int, val w: Int, val h: Int, val onClick: () -> Unit) {
    fun contains(px: Int, py: Int): Boolean = px >= x && px < x + w && py >= y && py < y + h
}

class LayoutNodeApplier(root: LayoutNode) : AbstractApplier<LayoutNode>(root) {
    override fun insertTopDown(index: Int, instance: LayoutNode) {
        current.children.add(index, instance)
    }
    override fun insertBottomUp(index: Int, instance: LayoutNode) {
        // built top-down
    }
    override fun remove(index: Int, count: Int) {
        var i = 0
        while (i < count) {
            current.children.removeAt(index)
            i += 1
        }
    }
    override fun move(from: Int, to: Int, count: Int) {
        // single-element move
        val el = current.children.removeAt(from)
        val dest = if (from > to) to else to - count
        current.children.add(dest, el)
    }
    override fun onClear() {
        root.children.clear()
    }
}

// ----- foundation composables -----

@Composable
fun Box(modifier: Modifier, content: @Composable () -> Unit) {
    ComposeNode<LayoutNode, LayoutNodeApplier>(
        factory = {
            val n = LayoutNode()
            n.arrangement = "Box"
            n
        },
        update = { set(modifier) { this.modifier = it } },
        content = content,
    )
}

@Composable
fun Box(modifier: Modifier) {
    ComposeNode<LayoutNode, LayoutNodeApplier>(
        factory = {
            val n = LayoutNode()
            n.arrangement = "Box"
            n
        },
        update = { set(modifier) { this.modifier = it } },
    )
}

@Composable
fun Row(modifier: Modifier, content: @Composable () -> Unit) {
    ComposeNode<LayoutNode, LayoutNodeApplier>(
        factory = {
            val n = LayoutNode()
            n.arrangement = "Row"
            n
        },
        update = { set(modifier) { this.modifier = it } },
        content = content,
    )
}

@Composable
fun Column(modifier: Modifier, content: @Composable () -> Unit) {
    ComposeNode<LayoutNode, LayoutNodeApplier>(
        factory = {
            val n = LayoutNode()
            n.arrangement = "Column"
            n
        },
        update = { set(modifier) { this.modifier = it } },
        content = content,
    )
}

@Composable
fun Text(text: String, color: Color, modifier: Modifier) {
    ComposeNode<LayoutNode, LayoutNodeApplier>(
        factory = {
            val n = LayoutNode()
            n.arrangement = "Box"
            n
        },
        update = {
            set(text) { this.text = it }
            set(color) { this.textColor = it }
            set(modifier) { this.modifier = it }
        },
    )
}

@Composable
fun Text(text: String, color: Color) {
    Text(text, color, Modifier.None)
}

/**
 * A lazy vertical list: only the items in the scrolled-into-view window are
 * composed (the item content for off-screen indices never runs), so a list of
 * thousands emits only a handful of nodes. Each visible item is keyed by its
 * index so its remembered state follows it across scroll. Changing [scrollOffset]
 * and recomposing brings a different window into view.
 */
@Composable
fun LazyColumn(
    itemCount: Int,
    itemHeight: Int,
    viewportHeight: Int,
    scrollOffset: Int,
    modifier: Modifier,
    itemContent: @Composable (Int) -> Unit,
) {
    val first = scrollOffset / itemHeight
    val windowCount = (viewportHeight + itemHeight - 1) / itemHeight + 1
    Column(modifier) {
        var i = first
        val last = first + windowCount
        while (i < last && i < itemCount) {
            key(i) { itemContent(i) }
            i += 1
        }
    }
}

@Composable
fun Button(label: String, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier.clickable(onClick).padding(1)) {
        Text(label, Color.White, Modifier.None)
    }
}

// ----- driver -----

/** Drives one composition into a LayoutNode tree, measures + lays it out under a
 * fixed [width] x [height], draws it into a software canvas, and returns it. */
class UiRenderer internal constructor(
    private val root: LayoutNode,
    private val width: Int,
    private val height: Int,
    private val recomposer: Recomposer,
    private val composition: Composition,
) {
    private val hits = ArrayList<HitRegion>()

    /** Measure/layout + draw the current tree, returning an ASCII pixel dump. */
    fun render(): String {
        root.measure(Constraints(width, width, height, height))
        val canvas = PixelCanvas(width, height)
        hits.clear()
        root.draw(canvas, 0, 0, hits)
        return canvas.toAscii()
    }

    /** Recompose after a state write, then render the next frame. */
    fun recomposeRender(): String {
        recomposer.recompose()
        return render()
    }

    /**
     * Dispatch a pointer click at ([px], [py]) to the topmost clickable region
     * hit (regions are collected front-to-back during draw, so the last match is
     * on top), then recompose + re-render. Returns the new frame, or the current
     * one if nothing was hit.
     */
    fun click(px: Int, py: Int): String {
        var handler: (() -> Unit)? = null
        for (region in hits) {
            if (region.contains(px, py)) handler = region.onClick
        }
        if (handler != null) {
            handler()
            return recomposeRender()
        }
        return render()
    }

    fun dispose() {
        composition.dispose()
    }
}

/** Compose [content] into a UI tree rendered onto a [width] x [height] canvas. */
fun uiRenderer(width: Int, height: Int, content: @Composable () -> Unit): UiRenderer {
    val root = LayoutNode()
    root.arrangement = "Box"
    root.modifier = Modifier.None.fillMaxSize()
    val recomposer = Recomposer()
    val composition = Composition(LayoutNodeApplier(root), recomposer)
    composition.setContent(content)
    return UiRenderer(root, width, height, recomposer, composition)
}
