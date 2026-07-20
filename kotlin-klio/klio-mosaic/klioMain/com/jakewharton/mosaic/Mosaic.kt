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
import androidx.compose.runtime.ControlledComposition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.snapshots.ObserverHandle
import androidx.compose.runtime.snapshots.Snapshot
import kotlin.coroutines.EmptyCoroutineContext

/** Drives one composition into a MosaicNode tree and renders it to text. */
public class MosaicRenderer internal constructor(
    private val rootNode: BoxNode,
    private val recomposer: Recomposer,
    private val composition: Composition,
) {
    /** State objects modified since the last recomposition. A snapshot apply
     * observer records the committed writes here so [recomposeFrame] can hand
     * them to the composition (the recomposer's own apply observer only runs
     * while its coroutine loop is active, which this synchronous driver never
     * starts). */
    private val pendingModifications = HashSet<Any>()
    private val applyObserver: ObserverHandle =
        Snapshot.registerApplyObserver { changed, _ -> pendingModifications.addAll(changed) }

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

    /** Apply pending state writes + recompose, then render the next frame.
     * Drives the composition synchronously through the real upstream
     * `ControlledComposition` API: publish the pending writes, invalidate the
     * scopes that read them, recompose, and apply the resulting node changes. */
    public fun recomposeFrame(): String {
        Snapshot.sendApplyNotifications()
        if (pendingModifications.isNotEmpty()) {
            val controlled = composition as ControlledComposition
            controlled.recordModificationsOf(pendingModifications.toSet())
            pendingModifications.clear()
            // Recompose inside a read-observing snapshot (mirrors the recomposer's
            // own `composing`): the read observer re-records the state each scope
            // reads, so a later write reinvalidates it. Without it a recomposed
            // scope loses its subscription and only the first write ever takes.
            val snapshot = Snapshot.takeMutableSnapshot(
                { value -> controlled.recordReadOf(value) },
                { value -> controlled.recordWriteOf(value) },
            )
            val changed = try {
                snapshot.enter { controlled.recompose() }
            } finally {
                snapshot.apply().check()
                snapshot.dispose()
            }
            if (changed) controlled.applyChanges()
        }
        return renderFrame()
    }

    /** Whether a state write has invalidated content not yet recomposed. */
    public val hasInvalidations: Boolean
        get() = composition.hasInvalidations

    /** Tear down the composition. */
    public fun dispose() {
        applyObserver.dispose()
        composition.dispose()
    }
}

/** Compose [content] into a fresh MosaicNode tree and return a renderer for it. */
public fun mosaicRenderer(content: @Composable () -> Unit): MosaicRenderer {
    val rootNode = BoxNode()
    val recomposer = Recomposer(EmptyCoroutineContext)
    val composition = Composition(MosaicNodeApplier(rootNode), recomposer)
    composition.setContent(content)
    return MosaicRenderer(rootNode, recomposer, composition)
}
