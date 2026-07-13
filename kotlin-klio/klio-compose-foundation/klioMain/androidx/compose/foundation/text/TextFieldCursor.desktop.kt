// Vendored from compose-multiplatform-core desktopMain (v1.11.1),
// androidx/compose/foundation/text/TextFieldCursor.desktop.kt.
//
// COPIED, not linked: the desktop source set as a whole depends on JVM APIs
// (java.awt clipboard, Swing context menus), which klio cannot satisfy — so the
// pack must not point at it. These files are the java-free subset, vendored so we
// own them and can adapt them to klio's platform surface.
package androidx.compose.foundation.text

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

internal actual val DefaultCursorThickness: Dp = 1.dp