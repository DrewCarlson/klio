// Vendored from compose-multiplatform-core desktopMain (v1.11.1),
// androidx/compose/foundation/text/TextFieldScroll.desktop.kt.
//
// COPIED, not linked: the desktop source set as a whole depends on JVM APIs
// (java.awt clipboard, Swing context menus), which klio cannot satisfy — so the
// pack must not point at it. These files are the java-free subset, vendored so we
// own them and can adapt them to klio's platform surface.
package androidx.compose.foundation.text

import androidx.compose.foundation.OverscrollEffect
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.VisualTransformation

@Composable
internal actual fun rememberTextFieldOverscrollEffect(): OverscrollEffect? = null

internal actual fun Modifier.textFieldScroll(
    scrollerPosition: TextFieldScrollerPosition,
    textFieldValue: TextFieldValue,
    visualTransformation: VisualTransformation,
    overscrollEffect: OverscrollEffect?,
    textLayoutResultProvider: () -> TextLayoutResultProxy?
): Modifier = defaultTextFieldScroll(
    scrollerPosition,
    textFieldValue,
    visualTransformation,
    overscrollEffect,
    textLayoutResultProvider,
)
