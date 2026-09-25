// corpus: skia
// Material 3's platform half, as the skiko targets ship it: DropdownMenu
// opens in a popup layer anchored under its button and takes the click on an
// item, AlertDialog opens a focusable dialog layer whose buttons dismiss it,
// and the date and time pickers format through the platform's CLDR data (the
// ICU the Skia shim bundles), so a date reads the way each locale writes it
// and the hour cycle follows the locale.
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.intl.Locale

/** Where each named node was last laid out in the window: its center. */
val centers = mutableMapOf<String, Offset>()

fun Modifier.track(name: String): Modifier = onGloballyPositioned {
    centers[name] = it.boundsInWindow().center
}

fun KlioComposeScene.settle() = repeat(20) { frame() }

fun KlioComposeScene.clickOn(name: String) {
    val at = centers.getValue(name)
    click(at.x, at.y)
    settle()
}

fun menu() {
    println("--- menu ---")
    var expanded by mutableStateOf(false)
    val scene = KlioComposeScene(400, 300)
    scene.setContent {
        MaterialTheme {
            Box(Modifier.fillMaxSize()) {
                Button(onClick = { expanded = true }, modifier = Modifier.track("button")) { Text("Open") }
                DropdownMenu(expanded = expanded, onDismissRequest = { println("menu dismissed"); expanded = false }) {
                    DropdownMenuItem(
                        text = { Text("Edit") },
                        onClick = { println("picked Edit"); expanded = false },
                        modifier = Modifier.track("edit"),
                    )
                    DropdownMenuItem(
                        text = { Text("Delete") },
                        onClick = { println("picked Delete"); expanded = false },
                        modifier = Modifier.track("delete"),
                    )
                }
            }
        }
    }
    scene.settle()
    println("menu open: $expanded, items laid out: ${"edit" in centers}")
    scene.clickOn("button")
    println("menu open: $expanded")
    val edit = centers.getValue("edit")
    val delete = centers.getValue("delete")
    val button = centers.getValue("button")
    println("items below the button: ${edit.y > button.y && delete.y > edit.y}")
    // The menu's surface is drawn in its layer, over the content.
    val pixels = scene.render().toPixelMap()
    val surface = pixels[edit.x.toInt(), edit.y.toInt()]
    println("item drawn on the menu surface: ${surface != Color.Transparent}")
    scene.clickOn("delete")
    println("menu open: $expanded")
    // A click outside the open menu dismisses it.
    scene.clickOn("button")
    scene.click(390f, 290f)
    scene.settle()
    println("menu open: $expanded")
    scene.dispose()
    centers.clear()
}

fun dialog() {
    println("--- dialog ---")
    var open by mutableStateOf(true)
    val scene = KlioComposeScene(400, 400)
    scene.setContent {
        MaterialTheme {
            if (open) {
                AlertDialog(
                    onDismissRequest = { println("dialog dismiss requested"); open = false },
                    confirmButton = {
                        TextButton(onClick = { println("confirmed"); open = false }, modifier = Modifier.track("ok")) {
                            Text("OK")
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { println("cancelled"); open = false }) { Text("Cancel") }
                    },
                    title = { Text("Discard draft?", modifier = Modifier.track("title")) },
                    text = { Text("The draft will be lost.") },
                )
            }
        }
    }
    scene.settle()
    val ok = centers.getValue("ok")
    val title = centers.getValue("title")
    println("title above the confirm button: ${title.y < ok.y}")
    // The scrim darkens the window around the dialog.
    val corner = scene.render().toPixelMap()[2, 2]
    println("scrim over the corner: ${corner.alpha > 0f && corner.toArgb() != Color.White.toArgb()}")
    scene.clickOn("ok")
    println("dialog open: $open")
    scene.dispose()
    centers.clear()
}

@OptIn(ExperimentalMaterial3Api::class)
fun dates() {
    println("--- dates ---")
    // 2024-03-15T00:00:00Z
    val millis = 1710460800000L
    val formatter = DatePickerDefaults.dateFormatter()
    for (tag in listOf("en-US", "en-GB", "de-DE", "fr-FR", "ja-JP")) {
        val locale = Locale(tag)
        println("$tag: ${formatter.formatDate(millis, locale)} | ${formatter.formatMonthYear(millis, locale)}")
    }
}

fun main() {
    menu()
    dialog()
    dates()
}
