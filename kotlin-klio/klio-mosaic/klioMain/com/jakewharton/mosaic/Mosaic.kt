// A synchronous mosaic driver for klio — the replacement for the upstream
// `runMosaic` (a runBlocking async terminal loop over jansi). It composes the
// content into the MosaicNode tree through a `Composition(MosaicNodeApplier, …)`,
// then renders frames to a plain String: compose once, mutate state + recompose,
// render again. This exercises the compose-runtime node-emission path
// (ComposeNode → Applier → measure/layout/render) deterministically, with no
// terminal, threads, or wall-clock.

package com.jakewharton.mosaic

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer

/** Drives one composition into a MosaicNode tree and renders it to text. */
public class MosaicRenderer internal constructor(
    private val rootNode: BoxNode,
    private val recomposer: Recomposer,
    private val composition: Composition,
) {
    /**
     * Render the current node tree to a plain-text frame — one line per row,
     * cells joined as characters. This reads the rendered canvas cells directly
     * rather than the canvas's ANSI writer, so the frame is a clean text buffer
     * (no colour/style escapes) and byte-identical whether the pack is loaded
     * from source or a baked image.
     */
    public fun renderFrame(): String {
        val canvas = rootNode.render()
        val sb = StringBuilder()
        var row = 0
        while (row < canvas.height) {
            var col = 0
            while (col < canvas.width) {
                sb.append(canvas[row, col].value.toChar())
                col += 1
            }
            if (row < canvas.height - 1) sb.append('\n')
            row += 1
        }
        return sb.toString()
    }

    /** Apply pending state writes + recompose, then render the next frame. */
    public fun recomposeFrame(): String {
        recomposer.recompose()
        return renderFrame()
    }

    /** Whether a state write has invalidated content not yet recomposed. */
    public val hasInvalidations: Boolean
        get() = composition.hasInvalidations

    /** Tear down the composition. */
    public fun dispose() {
        composition.dispose()
    }
}

/** Compose [content] into a fresh MosaicNode tree and return a renderer for it. */
public fun mosaicRenderer(content: @Composable () -> Unit): MosaicRenderer {
    val rootNode = BoxNode()
    val recomposer = Recomposer()
    val composition = Composition(MosaicNodeApplier(rootNode), recomposer)
    composition.setContent(content)
    return MosaicRenderer(rootNode, recomposer, composition)
}
