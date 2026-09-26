// A text field's context menu, as Compose Desktop's: a secondary click opens
// Cut, Copy, Paste and Select All at the pointer, with Paste disabled while
// the clipboard holds no text, and Select All selects the field's whole text.
// The click lands on a word already selected, which macOS would otherwise
// select first.
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp

fun main() {
    var value by mutableStateOf(TextFieldValue("hello menu", selection = TextRange(0, 5)))
    val scene = KlioComposeScene(300, 240)
    scene.setContent {
        BasicTextField(
            value = value,
            onValueChange = {
                if (it.selection != value.selection) println("selection ${it.selection}")
                value = it
            },
            modifier = Modifier.padding(10.dp).width(200.dp),
        )
    }
    val secondary = PointerButtons(isSecondaryPressed = true)
    scene.sendPointerEvent(PointerEventType.Press, Offset(20f, 18f), buttons = secondary, button = PointerButton.Secondary)
    scene.sendPointerEvent(PointerEventType.Release, Offset(20f, 18f), buttons = PointerButtons(), button = PointerButton.Secondary)
    scene.frame()
    scene.frame()
    // Select All, the menu's fourth item.
    scene.click(60f, 135f)
    scene.frame()
    println("text ${value.text}, selection ${value.selection}")
    scene.dispose()
}
