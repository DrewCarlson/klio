// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window's content as assistive technologies see it, as a Compose Desktop
// window's: each semantics node is an accessible element with the role its
// semantics give it (a button, a checkbox, a text field, a slider, text),
// its name and value, and its actions. The accessibility requests come from
// compose_window_accessibility.input, made through the platform's
// accessibility API as a screen reader makes them: its tree is dumped, the
// button pressed, the checkbox toggled, the field given text and the
// slider stepped, and the tree dumped again.
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.clickable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "accessibility") {
            var count by remember { mutableIntStateOf(0) }
            var subscribed by remember { mutableStateOf(false) }
            var name by remember { mutableStateOf("") }
            var volume by remember { mutableFloatStateOf(0.5f) }
            Column {
                BasicText("Settings", Modifier.semantics { heading() })
                BasicText(
                    "Add",
                    Modifier.clickable(role = Role.Button) {
                        count++
                        println("clicked $count")
                    },
                )
                BasicText(
                    "Subscribe",
                    Modifier.toggleable(value = subscribed, role = Role.Checkbox) {
                        subscribed = it
                        println("subscribed $it")
                    },
                )
                BasicTextField(
                    value = name,
                    onValueChange = {
                        name = it
                        println("name $it")
                    },
                    modifier = Modifier.width(120.dp).semantics { contentDescription = "Name" },
                )
                Box(
                    Modifier.size(100.dp, 20.dp).semantics {
                        contentDescription = "Volume"
                        progressBarRangeInfo = ProgressBarRangeInfo(volume, 0f..1f, steps = 9)
                        setProgress { value ->
                            volume = value
                            println("volume ${(value * 10).toInt()}")
                            true
                        }
                    },
                )
            }
        }
    }
    println("application ended")
}
