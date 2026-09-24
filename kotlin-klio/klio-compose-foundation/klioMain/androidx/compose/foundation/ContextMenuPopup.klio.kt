/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation

import androidx.compose.foundation.text.contextmenu.data.TextContextMenuComponent
import androidx.compose.foundation.text.contextmenu.data.TextContextMenuSession
import androidx.compose.runtime.Composable
import androidx.compose.ui.window.PopupPositionProvider

/**
 * The skiko text context menu's popup (BasicContextMenuRepresentation.skiko.kt
 * upstream), which the default dropdown provider opens. Upstream draws the menu
 * in a focusable Popup with key navigation; klio has no popup layer, so opening
 * the menu reports that. Upstream's trailing `colors` parameter, which only
 * styles the popup, is left out.
 */
@Composable
internal fun DefaultOpenContextMenu(
    session: TextContextMenuSession,
    components: List<TextContextMenuComponent>,
    popupPositionProvider: PopupPositionProvider,
) {
    throw UnsupportedOperationException("klio: context menu popups are not supported")
}
