// Vendored from compose-multiplatform-core desktopMain (v1.12.0),
// androidx/compose/foundation/window/WindowDraggableArea.desktop.kt, over a
// klio window: a press starts moving the window with the mouse, as upstream's
// StandardMoveHandler moves an AWT window, through the window's
// LocalWindowMoveWithMouse.
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

package androidx.compose.foundation.window

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.window.LocalWindowMoveWithMouse
import androidx.compose.ui.window.WindowScope

/**
 * WindowDraggableArea is a component that allows you to drag the window using the mouse.
 *
 * @param modifier The modifier to be applied to the layout.
 * @param content The content lambda.
 */
@OptIn(InternalComposeUiApi::class)
@Composable
fun WindowScope.WindowDraggableArea(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit = {}
) {
    val startMovingTogetherWithMouse by rememberUpdatedState(LocalWindowMoveWithMouse.current)
    Box(
        modifier = modifier.pointerInput(Unit) {
            awaitEachGesture {
                awaitFirstDown()
                startMovingTogetherWithMouse?.invoke()
            }
        },
        propagateMinConstraints = true,
        content = { content() }
    )
}
