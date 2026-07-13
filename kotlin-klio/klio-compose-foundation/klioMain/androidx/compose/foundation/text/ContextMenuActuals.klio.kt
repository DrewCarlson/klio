/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text

import androidx.compose.foundation.text.input.internal.selection.TextFieldSelectionState
import androidx.compose.foundation.text.selection.SelectionManager
import androidx.compose.foundation.text.selection.TextFieldSelectionManager
import androidx.compose.runtime.Composable

/**
 * klio actuals for the three text context-menu areas.
 *
 * A context menu is a platform popup window: upstream's desktop actuals hand the
 * area to `LocalTextContextMenu`, whose default representation opens a Swing
 * `JPopupMenu`. klio's window layer has no popup surface, so there is nothing for
 * the area to open onto and the actual is the content itself. Cut/copy/paste stay
 * reachable through the key bindings, which is where a text field's editing
 * commands actually run; only the right-click menu is absent.
 *
 * These are `expect`s with no common body, so a text field cannot compose at all
 * without them: `CoreTextFieldRootBox` wraps every `BasicTextField` in one.
 */
@Composable
internal actual fun ContextMenuArea(
    manager: TextFieldSelectionManager,
    content: @Composable () -> Unit,
) {
    content()
}

@Composable
internal actual fun ContextMenuArea(
    selectionState: TextFieldSelectionState,
    enabled: Boolean,
    content: @Composable () -> Unit,
) {
    content()
}

@Composable
internal actual fun ContextMenuArea(manager: SelectionManager, content: @Composable () -> Unit) {
    content()
}
