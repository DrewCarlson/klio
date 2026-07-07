// Compose UI material layer — a themed surface + button, driven by a
// CompositionLocal colour scheme (the compose runtime's CompositionLocal wired
// into the ui-core). MaterialTheme provides a ColorScheme; a Card paints the
// theme's surface + outline, a PrimaryButton the theme's primary colour, and a
// Text the onSurface colour — all resolved from the nearest theme via `.current`.
// Two themes render the same UI in different palettes.

import klio.compose.ui.Card
import klio.compose.ui.Color
import klio.compose.ui.ColorScheme
import klio.compose.ui.Column
import klio.compose.ui.LocalColorScheme
import klio.compose.ui.MaterialTheme
import klio.compose.ui.Modifier
import klio.compose.ui.PrimaryButton
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer
import androidx.compose.runtime.Composable

@Composable
fun Screen() {
    val scheme = LocalColorScheme.current
    Card(Modifier.None) {
        Column(Modifier.None.padding(1)) {
            Text("HI", scheme.onSurface, Modifier.None)
            PrimaryButton("OK") { }
        }
    }
}

fun main() {
    val light = ColorScheme(Color.Blue, Color.White, Color.Black, Color.Gray)
    val dark = ColorScheme(Color.Cyan, Color.Black, Color.White, Color.Blue)

    val lightUi = uiRenderer(18, 12) { MaterialTheme(light) { Screen() } }
    println("--- light theme ---")
    println(lightUi.displayList())
    lightUi.dispose()

    val darkUi = uiRenderer(18, 12) { MaterialTheme(dark) { Screen() } }
    println("--- dark theme ---")
    println(darkUi.displayList())
    darkUi.dispose()
}
