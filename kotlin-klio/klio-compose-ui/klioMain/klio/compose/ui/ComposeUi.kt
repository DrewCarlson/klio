// A minimal Compose UI core rendered by Skia. A @Composable tree emits LayoutNodes
// through the compose runtime's node path (ComposeNode -> LayoutNodeApplier); a
// measure pass sizes and places them under Constraints, and a draw pass records a
// display list of draw ops (fills, stroked/rounded rects, text). The list is
// replayed onto a real Skia raster surface by the native backend (src/compose_ui
// + libklio_skia) to produce a PNG. The display list is itself a deterministic,
// human-readable render artifact, so tests assert on it without needing Skia.

package klio.compose.ui

import androidx.compose.runtime.AbstractApplier
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.ComposeNode
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.key

// ----- color -----

/** A packed ARGB color (0xAARRGGBB), the value Skia paints with. */
class Color(val argb: Int) {
    companion object {
        val Transparent = Color(0x00000000)
        val Black = Color(0xFF000000.toInt())
        val White = Color(0xFFFFFFFF.toInt())
        val Red = Color(0xFFF44336.toInt())
        val Green = Color(0xFF4CAF50.toInt())
        val Blue = Color(0xFF2196F3.toInt())
        val Yellow = Color(0xFFFFEB3B.toInt())
        val Cyan = Color(0xFF00BCD4.toInt())
        val Magenta = Color(0xFFE91E63.toInt())
        val Gray = Color(0xFF9E9E9E.toInt())
    }
}

// ----- display list -----

/** A recorded list of draw ops in the text format the native Skia backend replays
 * (see src/compose_ui skiaRender). Colors are 8-hex-digit ARGB; coordinates are
 * pixels. It doubles as the deterministic render artifact tests assert on. */
class DisplayList {
    private val sb = StringBuilder()

    private fun hex(argb: Int): String {
        val h = (argb.toLong() and 0xFFFFFFFFL).toString(16).uppercase()
        val pad = 8 - h.length
        return if (pad > 0) "0".repeat(pad) + h else h
    }

    fun clear(argb: Int) {
        sb.append("clear ").append(hex(argb)).append('\n')
    }

    fun fillRect(x: Int, y: Int, w: Int, h: Int, argb: Int) {
        sb.append("rect ").append(x).append(' ').append(y).append(' ').append(w).append(' ')
            .append(h).append(' ').append(hex(argb)).append('\n')
    }

    fun strokeRect(x: Int, y: Int, w: Int, h: Int, stroke: Int, argb: Int) {
        sb.append("srect ").append(x).append(' ').append(y).append(' ').append(w).append(' ')
            .append(h).append(' ').append(stroke).append(' ').append(hex(argb)).append('\n')
    }

    fun roundRect(x: Int, y: Int, w: Int, h: Int, radius: Int, argb: Int) {
        sb.append("rrect ").append(x).append(' ').append(y).append(' ').append(w).append(' ')
            .append(h).append(' ').append(radius).append(' ').append(radius).append(' ')
            .append(hex(argb)).append('\n')
    }

    fun circle(cx: Int, cy: Int, r: Int, argb: Int) {
        sb.append("circle ").append(cx).append(' ').append(cy).append(' ').append(r).append(' ')
            .append(hex(argb)).append('\n')
    }

    fun line(x0: Int, y0: Int, x1: Int, y1: Int, stroke: Int, argb: Int) {
        sb.append("line ").append(x0).append(' ').append(y0).append(' ').append(x1).append(' ')
            .append(y1).append(' ').append(stroke).append(' ').append(hex(argb)).append('\n')
    }

    fun drawText(x: Int, y: Int, size: Int, argb: Int, s: String) {
        sb.append("text ").append(x).append(' ').append(y).append(' ').append(size).append(' ')
            .append(hex(argb)).append(' ').append(s).append('\n')
    }

    fun encoded(): String = sb.toString()
}

// ----- geometry -----

/** Measurement bounds handed down the tree during the measure pass. */
class Constraints(val minWidth: Int, val maxWidth: Int, val minHeight: Int, val maxHeight: Int)

private fun clamp(value: Int, lo: Int, hi: Int): Int {
    if (value < lo) return lo
    if (value > hi) return hi
    return value
}

// Nominal text metrics (layout units) — the measure pass sizes text boxes with
// these; the Skia render uses the same nominal glyph height so layout and paint
// agree without a font-metric round trip through the backend.
private const val GLYPH_H = 5
private const val GLYPH_ADVANCE = 4 // per-character width incl. gap

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
    val border: Color?,
    val cornerRadius: Int,
) {
    private fun copy(
        width: Int = this.width,
        height: Int = this.height,
        padding: Int = this.padding,
        background: Color? = this.background,
        fillMaxWidth: Boolean = this.fillMaxWidth,
        fillMaxHeight: Boolean = this.fillMaxHeight,
        onClick: (() -> Unit)? = this.onClick,
        border: Color? = this.border,
        cornerRadius: Int = this.cornerRadius,
    ): Modifier = Modifier(width, height, padding, background, fillMaxWidth, fillMaxHeight, onClick, border, cornerRadius)

    fun size(w: Int, h: Int): Modifier = copy(width = w, height = h)
    fun width(w: Int): Modifier = copy(width = w)
    fun height(h: Int): Modifier = copy(height = h)
    fun padding(p: Int): Modifier = copy(padding = p)
    fun background(c: Color): Modifier = copy(background = c)
    fun fillMaxWidth(): Modifier = copy(fillMaxWidth = true)
    fun fillMaxHeight(): Modifier = copy(fillMaxHeight = true)
    fun fillMaxSize(): Modifier = copy(fillMaxWidth = true, fillMaxHeight = true)
    fun clickable(onClick: () -> Unit): Modifier = copy(onClick = onClick)
    fun border(c: Color): Modifier = copy(border = c)
    fun cornerRadius(r: Int): Modifier = copy(cornerRadius = r)

    companion object {
        val None = Modifier(-1, -1, 0, null, false, false, null, null, 0)
    }
}

// ----- layout node + applier -----

/** The layout node — the applier's node type. Measures + places its children
 * per its [arrangement], then records draw ops for its background and children. */
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

    /** Record draw ops for this node (background/border/text) + children into
     * [list], scaling layout units by [scale], and collect clickable regions
     * (in unscaled layout units). */
    fun draw(list: DisplayList, originX: Int, originY: Int, scale: Int, hits: MutableList<HitRegion>) {
        val stroke = if (scale < 1) 1 else scale
        val bg = modifier.background
        if (bg != null) {
            val x = originX * scale
            val y = originY * scale
            val w = measuredWidth * scale
            val h = measuredHeight * scale
            if (modifier.cornerRadius > 0) {
                list.roundRect(x, y, w, h, modifier.cornerRadius * scale, bg.argb)
            } else {
                list.fillRect(x, y, w, h, bg.argb)
            }
        }
        val brd = modifier.border
        if (brd != null) {
            list.strokeRect(originX * scale, originY * scale, measuredWidth * scale, measuredHeight * scale, stroke, brd.argb)
        }
        val onClick = modifier.onClick
        if (onClick != null) {
            hits.add(HitRegion(originX, originY, measuredWidth, measuredHeight, onClick))
        }
        val pad = modifier.padding
        if (text.isNotEmpty()) {
            val fg = textColor ?: Color.White
            val size = GLYPH_H * scale
            // Skia text origin is the baseline; place it a glyph-height below the
            // padded top-left so it sits inside the box.
            val tx = (originX + pad) * scale
            val baseline = (originY + pad) * scale + size
            list.drawText(tx, baseline, size, fg.argb, text)
        }
        for (child in children) {
            child.draw(list, originX + child.offsetX, originY + child.offsetY, scale, hits)
        }
    }
}

/** A clickable region collected during the draw pass (absolute layout bounds + handler). */
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
fun Spacer(width: Int, height: Int) {
    Box(Modifier.None.size(width, height))
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

// ----- material (a themed layer on the foundation, via CompositionLocal) -----

/** A material-style colour scheme, provided to a subtree by [MaterialTheme]. */
class ColorScheme(
    val primary: Color,
    val surface: Color,
    val onSurface: Color,
    val outline: Color,
)

val defaultColorScheme: ColorScheme = ColorScheme(Color.Blue, Color.Gray, Color.Black, Color.White)

/** The nearest [ColorScheme]; themed components read it via `.current`. */
val LocalColorScheme = compositionLocalOf { defaultColorScheme }

/** Provide [scheme] to [content] and everything it composes. */
@Composable
fun MaterialTheme(scheme: ColorScheme, content: @Composable () -> Unit) {
    CompositionLocalProvider(LocalColorScheme provides scheme) {
        content()
    }
}

/** A surface card: the theme's surface fill + outline border + padding. */
@Composable
fun Card(modifier: Modifier, content: @Composable () -> Unit) {
    val scheme = LocalColorScheme.current
    Box(modifier.background(scheme.surface).border(scheme.outline).padding(1), content)
}

/** A filled button in the theme's primary colour. */
@Composable
fun PrimaryButton(label: String, onClick: () -> Unit) {
    val scheme = LocalColorScheme.current
    Button(label, Modifier.None.background(scheme.primary), onClick)
}

// ----- driver -----

/** Drives one composition into a LayoutNode tree, measures + lays it out under a
 * fixed [width] x [height], records a display list, and renders it via Skia. */
class UiRenderer internal constructor(
    private val root: LayoutNode,
    private val width: Int,
    private val height: Int,
    private val recomposer: Recomposer,
    private val composition: Composition,
) {
    private val hits = ArrayList<HitRegion>()

    /** Measure/layout + record a display list, collecting hit regions. */
    private fun build(scale: Int): DisplayList {
        root.measure(Constraints(width, width, height, height))
        val list = DisplayList()
        hits.clear()
        root.draw(list, 0, 0, scale, hits)
        return list
    }

    /** The current frame's display list text (the deterministic render artifact). */
    fun displayList(scale: Int): String = build(scale).encoded()

    fun displayList(): String = displayList(1)

    /**
     * Render the current frame to a PNG at [path] (layout units scaled [scale]x)
     * through the Skia backend, returning an FNV-1a checksum of the encoded bytes
     * (0 if the Skia library is unavailable).
     */
    fun savePng(path: String, scale: Int): Long {
        val list = build(scale)
        return renderDisplayListToPng(path, width * scale, height * scale, list.encoded())
    }

    /** Recompose after a state write, then return the next frame's display list. */
    fun recomposeDisplayList(scale: Int): String {
        recomposer.recompose()
        return displayList(scale)
    }

    fun recomposeDisplayList(): String = recomposeDisplayList(1)

    fun click(px: Int, py: Int): String = click(px, py, 1)

    /**
     * Dispatch a pointer click at ([px], [py], in layout units) to the topmost
     * clickable region hit (regions are collected front-to-back, so the last match
     * is on top), then recompose. Returns the new frame's display list, or the
     * current one if nothing was hit. Requires a prior [displayList]/[savePng] to
     * have populated the hit regions.
     */
    fun click(px: Int, py: Int, scale: Int): String {
        var handler: (() -> Unit)? = null
        for (region in hits) {
            if (region.contains(px, py)) handler = region.onClick
        }
        if (handler != null) {
            handler()
            return recomposeDisplayList(scale)
        }
        return displayList(scale)
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
