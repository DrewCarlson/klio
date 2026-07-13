// Vendored from compose-multiplatform-core desktopMain (v1.11.1),
// androidx/compose/foundation/text/input/internal/selection/TextFieldMagnifierNode.desktop.kt.
//
// COPIED, not linked: the desktop source set as a whole depends on JVM APIs
// (java.awt clipboard, Swing context menus), which klio cannot satisfy — so the
// pack must not point at it. These files are the java-free subset, vendored so we
// own them and can adapt them to klio's platform surface.
/*
 * Copyright 2024 The Android Open Source Project
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

package androidx.compose.foundation.text.input.internal.selection

import androidx.compose.foundation.text.input.internal.TextLayoutState
import androidx.compose.foundation.text.input.internal.TransformedTextFieldState

/**
 * Initializes either an actual TextFieldMagnifierNode implementation or No-op node according to
 * whether magnifier is supported.
 */
internal actual fun textFieldMagnifierNode(
    textFieldState: TransformedTextFieldState,
    textFieldSelectionState: TextFieldSelectionState,
    textLayoutState: TextLayoutState,
    visible: Boolean
): TextFieldMagnifierNode {
    return object : TextFieldMagnifierNode() {
        override fun update(
            textFieldState: TransformedTextFieldState,
            textFieldSelectionState: TextFieldSelectionState,
            textLayoutState: TextLayoutState,
            visible: Boolean
        ) {}
    }
}