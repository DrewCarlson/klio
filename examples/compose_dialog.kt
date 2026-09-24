// A Dialog opens a focusable layer above the content, centered in the window,
// with a scrim over everything below it. The platform default width caps its
// content at 440 dp in a window whose smaller side is 480 to 600 dp. The
// dialog holds the pointer: a click around it reaches nothing below, and its
// release asks the dialog to dismiss unless dismissOnClickOutside is off. The
// dialog fades and scales in and out over the frame clock, and holds the
// input until it has faded out. Setting ComposeUiFlags.isDialogAnimationEnabled
// to false turns that animation off, and then the dialog goes in the next frame.
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ComposeUiFlags
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.isDialogAnimationEnabled
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

fun Modifier.reportPosition(name: String): Modifier = onGloballyPositioned {
    println("$name at ${it.positionInWindow()} size ${it.size}")
}

/** Runs frames until the dialog's entry or exit animation (at most 0.2 s) is over. */
fun KlioComposeScene.settle() = repeat(15) { frame() }

fun clicks(name: String, properties: DialogProperties) {
    println("--- $name ---")
    var shown by mutableStateOf(true)
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Box(Modifier.fillMaxSize().clickable { println("content clicked") }) {
            if (shown) {
                Dialog(
                    onDismissRequest = { println("dismiss requested"); shown = false },
                    properties = properties,
                ) {
                    Box(
                        Modifier.size(80.dp).background(Color.Blue)
                            .reportPosition("dialog")
                            .clickable { println("dialog clicked") }
                    )
                }
            }
        }
    }
    scene.settle()
    println("click inside")
    scene.click(100f, 100f)
    println("click outside")
    scene.click(10f, 10f)
    println("shown=$shown")
    scene.settle()
    println("click outside again")
    scene.click(10f, 10f)
    scene.dispose()
}

fun defaultWidth() {
    println("--- platform default width ---")
    val scene = KlioComposeScene(700, 500)
    scene.setContent {
        Dialog(onDismissRequest = {}) {
            Box(Modifier.fillMaxWidth().height(40.dp).reportPosition("default width"))
        }
        Dialog(onDismissRequest = {}, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Box(Modifier.fillMaxWidth().height(40.dp).reportPosition("full width"))
        }
    }
    scene.settle()
    scene.dispose()
}

@OptIn(ExperimentalComposeUiApi::class)
fun withoutAnimation() {
    println("--- without the animation ---")
    ComposeUiFlags.isDialogAnimationEnabled = false
    var shown by mutableStateOf(true)
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        Box(Modifier.fillMaxSize().clickable { println("content clicked") }) {
            if (shown) {
                Dialog(onDismissRequest = { println("dismiss requested"); shown = false }) {
                    Box(Modifier.size(80.dp).background(Color.Blue))
                }
            }
        }
    }
    println("click outside")
    scene.click(10f, 10f)
    println("click outside in the next frame")
    scene.click(10f, 10f)
    scene.dispose()
    ComposeUiFlags.isDialogAnimationEnabled = true
}

fun main() {
    clicks("dialog", DialogProperties())
    clicks("kept on outside click", DialogProperties(dismissOnClickOutside = false))
    defaultWidth()
    withoutAnimation()
}
