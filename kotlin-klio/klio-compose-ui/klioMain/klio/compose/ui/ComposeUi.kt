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
) {
    fun size(w: Int, h: Int): Modifier = Modifier(w, h, padding, background, fillMaxWidth, fillMaxHeight)
    fun width(w: Int): Modifier = Modifier(w, height, padding, background, fillMaxWidth, fillMaxHeight)
    fun height(h: Int): Modifier = Modifier(width, h, padding, background, fillMaxWidth, fillMaxHeight)
    fun padding(p: Int): Modifier = Modifier(width, height, p, background, fillMaxWidth, fillMaxHeight)
    fun background(c: Color): Modifier = Modifier(width, height, padding, c, fillMaxWidth, fillMaxHeight)
    fun fillMaxWidth(): Modifier = Modifier(width, height, padding, background, true, fillMaxHeight)
    fun fillMaxHeight(): Modifier = Modifier(width, height, padding, background, fillMaxWidth, true)
    fun fillMaxSize(): Modifier = Modifier(width, height, padding, background, true, true)

    companion object {
        val None = Modifier(-1, -1, 0, null, false, false)
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

    fun draw(canvas: PixelCanvas, originX: Int, originY: Int) {
        val bg = modifier.background
        if (bg != null) canvas.fillRect(originX, originY, measuredWidth, measuredHeight, bg.argb)
        for (child in children) {
            child.draw(canvas, originX + child.offsetX, originY + child.offsetY)
        }
    }
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
    /** Measure/layout + draw the current tree, returning an ASCII pixel dump. */
    fun render(): String {
        root.measure(Constraints(width, width, height, height))
        val canvas = PixelCanvas(width, height)
        root.draw(canvas, 0, 0)
        return canvas.toAscii()
    }

    /** Recompose after a state write, then render the next frame. */
    fun recomposeRender(): String {
        recomposer.recompose()
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
