// corpus: interactive — loops on a live window (maxFrames = -1) until the user closes it.
// An advanced windowed Material 3 app: a themed dashboard with a light/dark
// toggle, tab navigation, an interactive counter, a toggleable task list, and an
// about pane — the full state -> recompose -> Skia draw loop, staying open until
// the window is closed (maxFrames = -1). Run on a machine with a display and the
// Skia library available (see the command in the header of examples/README.md);
// headless, runApp returns immediately so there is no baked corpus output.

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import klio.compose.ui.ALIGN_LEFT
import klio.compose.ui.Box
import klio.compose.ui.Card
import klio.compose.ui.Color
import klio.compose.ui.ColorScheme
import klio.compose.ui.Column
import klio.compose.ui.LocalColorScheme
import klio.compose.ui.MaterialTheme
import klio.compose.ui.Modifier
import klio.compose.ui.Paragraph
import klio.compose.ui.Row
import klio.compose.ui.Spacer
import klio.compose.ui.Text
import klio.compose.ui.runApp

// ---- Material 3 palettes (light + dark) ----

val LightScheme = ColorScheme(
    primary = Color(0xFF6750A4.toInt()),
    surface = Color(0xFFFDF7FF.toInt()),
    onSurface = Color(0xFF1C1B1F.toInt()),
    outline = Color(0xFFCAC4D0.toInt()),
)

val DarkScheme = ColorScheme(
    primary = Color(0xFFD0BCFF.toInt()),
    surface = Color(0xFF1C1B1F.toInt()),
    onSurface = Color(0xFFE6E1E5.toInt()),
    outline = Color(0xFF49454F.toInt()),
)

// ---- reusable themed widgets ----

// A filled/tonal chip that reads its colours from the theme and reports clicks;
// `selected` fills it with the primary colour, otherwise it's a tonal surface.
@Composable
fun Chip(label: String, selected: Boolean, onClick: () -> Unit) {
    val scheme = LocalColorScheme.current
    var hovered by remember { mutableStateOf(false) }
    val bg = if (selected) scheme.primary else scheme.surface
    val fg = if (selected) scheme.surface else scheme.onSurface
    val border = if (hovered) scheme.primary else scheme.outline
    Box(
        Modifier.None
            .background(bg)
            .border(border)
            .cornerRadius(1)
            .padding(1)
            .onHover { hovered = it }
            .clickable(onClick),
    ) {
        Text(label, fg, Modifier.None)
    }
}

// The app bar: title on the left, a light/dark toggle on the right.
@Composable
fun AppBar(dark: Boolean, onToggleTheme: () -> Unit) {
    val scheme = LocalColorScheme.current
    Row(Modifier.None.fillMaxWidth().background(scheme.primary).padding(1)) {
        Text("KLIO  DASHBOARD", scheme.surface, Modifier.None)
        Spacer(6, 1)
        Chip(if (dark) "LIGHT" else "DARK", false, onToggleTheme)
    }
}

@Composable
fun TabBar(tab: Int, onSelect: (Int) -> Unit) {
    Row(Modifier.None.padding(1)) {
        Chip("COUNTER", tab == 0) { onSelect(0) }
        Spacer(1, 1)
        Chip("TASKS", tab == 1) { onSelect(1) }
        Spacer(1, 1)
        Chip("ABOUT", tab == 2) { onSelect(2) }
    }
}

@Composable
fun CounterView(count: Int, onDelta: (Int) -> Unit, onReset: () -> Unit) {
    val scheme = LocalColorScheme.current
    Card(Modifier.None.fillMaxWidth()) {
        Column(Modifier.None.padding(1)) {
            Text("INTERACTIVE COUNTER", scheme.onSurface, Modifier.None)
            Spacer(1, 1)
            Text("VALUE  " + count, scheme.primary, Modifier.None)
            Spacer(1, 1)
            Row(Modifier.None) {
                Chip("-", false) { onDelta(-1) }
                Spacer(1, 1)
                Chip("RESET", false) { onReset() }
                Spacer(1, 1)
                Chip("+", false) { onDelta(1) }
            }
        }
    }
}

@Composable
fun TasksView(tasks: List<String>, done: Set<Int>, onToggle: (Int) -> Unit) {
    val scheme = LocalColorScheme.current
    Card(Modifier.None.fillMaxWidth()) {
        Column(Modifier.None.padding(1)) {
            Text("TASKS  " + done.size + "/" + tasks.size, scheme.onSurface, Modifier.None)
            Spacer(1, 1)
            var i = 0
            while (i < tasks.size) {
                val idx = i
                val checked = done.contains(idx)
                val mark = if (checked) "[x] " else "[ ] "
                val fg = if (checked) scheme.outline else scheme.onSurface
                Box(
                    Modifier.None.fillMaxWidth().padding(1).clickable { onToggle(idx) },
                ) {
                    Text(mark + tasks[idx], fg, Modifier.None)
                }
                i += 1
            }
        }
    }
}

@Composable
fun AboutView() {
    val scheme = LocalColorScheme.current
    Card(Modifier.None.fillMaxWidth()) {
        Column(Modifier.None.padding(1)) {
            Text("ABOUT", scheme.onSurface, Modifier.None)
            Spacer(1, 1)
            Paragraph(
                "This dashboard is a Compose UI tree interpreted by KLIO and " +
                    "painted by Skia. Clicks and hovers flow through the same " +
                    "state to recomposition to draw loop as Jetpack Compose.",
                scheme.onSurface,
                104,
                ALIGN_LEFT,
                Modifier.None,
            )
        }
    }
}

@Composable
fun Dashboard() {
    var dark by remember { mutableStateOf(false) }
    var tab by remember { mutableStateOf(0) }
    var count by remember { mutableStateOf(0) }
    var done by remember { mutableStateOf(setOf<Int>()) }

    val tasks = listOf(
        "Port the interpreter to Zig",
        "Reach 100% stdlib coverage",
        "Wire the Compose runtime",
        "Render with Skia",
    )

    MaterialTheme(if (dark) DarkScheme else LightScheme) {
        val scheme = LocalColorScheme.current
        Column(Modifier.None.fillMaxSize().background(scheme.surface)) {
            AppBar(dark) { dark = !dark }
            TabBar(tab) { tab = it }
            Spacer(1, 1)
            Box(Modifier.None.fillMaxWidth().padding(1)) {
                when (tab) {
                    0 -> CounterView(
                        count,
                        onDelta = { d -> count += d },
                        onReset = { count = 0 },
                    )
                    1 -> TasksView(tasks, done) { idx ->
                        done = if (done.contains(idx)) done - idx else done + idx
                    }
                    else -> AboutView()
                }
            }
            Spacer(1, 1)
            Text(
                "theme " + (if (dark) "dark" else "light") + "   tab " + tab,
                scheme.outline,
                Modifier.None.padding(1),
            )
        }
    }
}

fun main() {
    // Text lays out at ~4 layout units per character, so the space is 120 units
    // wide (~30 chars) to fit the longest labels. 120x72 units at 8x scale = a
    // 960x576 window. maxFrames = -1 keeps the window open until it is closed.
    runApp(120, 72, 8, "KLIO Compose — Material 3 Dashboard", -1) {
        Dashboard()
    }
}
