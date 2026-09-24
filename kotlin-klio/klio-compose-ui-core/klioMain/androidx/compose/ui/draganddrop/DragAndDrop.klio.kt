/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// The drag-and-drop types of ui's DragAndDrop.kt, as desktop declares them
// (DragAndDrop.desktop.kt) without the AWT transfer layer: a transfer carries
// a DragAndDropTransferable and its actions, and an event its action, the
// platform's own event and where it is in the root.
package androidx.compose.ui.draganddrop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.painter.Painter

actual class DragAndDropTransferData @ExperimentalComposeUiApi constructor(
    @property:ExperimentalComposeUiApi
    val transferable: DragAndDropTransferable,
    @property:ExperimentalComposeUiApi
    val supportedActions: Iterable<DragAndDropTransferAction>,
    @property:ExperimentalComposeUiApi
    val dragDecorationOffset: Offset = Offset.Zero,
    @property:ExperimentalComposeUiApi
    val onTransferCompleted: ((userAction: DragAndDropTransferAction?) -> Unit)? = null,
) {
    init {
        require(supportedActions.firstOrNull() != null) { "supportedActions may not be empty" }
    }
}

@ExperimentalComposeUiApi
interface DragAndDropTransferable

@ExperimentalComposeUiApi
class DragAndDropTransferAction private constructor(private val name: String) {
    override fun toString(): String {
        return name
    }

    companion object {
        val Copy = DragAndDropTransferAction("Copy")
        val Move = DragAndDropTransferAction("Move")
        val Link = DragAndDropTransferAction("Link")
    }
}

actual class DragAndDropEvent @ExperimentalComposeUiApi constructor(
    @property:ExperimentalComposeUiApi
    val action: DragAndDropTransferAction?,
    @property:ExperimentalComposeUiApi
    val nativeEvent: Any?,
    internal val positionInRootImpl: Offset
)

@ExperimentalComposeUiApi
interface DragData {
    interface FilesList : DragData {
        fun readFiles(): List<String>
    }

    interface Image : DragData {
        fun readImage(): Painter
    }

    interface Text : DragData {
        val bestMimeType: String
        fun readText(): String
    }
}

internal actual val DragAndDropEvent.positionInRoot: Offset
    get() = positionInRootImpl
