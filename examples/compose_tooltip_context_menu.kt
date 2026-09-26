// A TooltipArea shows its tooltip once the pointer rests on it for its delay
// and hides it when the pointer leaves; a ContextMenuArea opens its menu at a
// secondary click, runs the item clicked and closes. Both place their popups
// with the desktop's position providers, as Compose Desktop does.
import androidx.compose.foundation.ContextMenuArea
import androidx.compose.foundation.ContextMenuItem
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.TooltipArea
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerButton
import androidx.compose.ui.input.pointer.PointerButtons
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking

@OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)
fun main() {
    val scene = KlioComposeScene(300, 240)
    scene.setContent {
        Column {
            TooltipArea(
                tooltip = {
                    DisposableEffect(Unit) {
                        println("tooltip shown")
                        onDispose { println("tooltip hidden") }
                    }
                    BasicText(
                        "A tooltip",
                        Modifier.background(Color.LightGray).onGloballyPositioned {
                            println("tooltip at ${it.positionInRoot()}")
                        },
                    )
                },
                delayMillis = 100,
            ) {
                Box(Modifier.size(120.dp, 40.dp).background(Color.Gray))
            }
            ContextMenuArea(
                items = {
                    listOf(
                        ContextMenuItem("Copy") { println("copy chosen") },
                        ContextMenuItem("Paste") { println("paste chosen") },
                    )
                },
            ) {
                Box(Modifier.size(120.dp, 40.dp).background(Color.Blue))
            }
        }
    }
    // Rest on the tooltip area past its delay, then leave it.
    scene.hover(60f, 20f)
    runBlocking { delay(400) }
    scene.frame()
    scene.frame()
    scene.hover(250f, 200f)
    scene.frame()
    // A secondary click on the menu area opens its menu at the pointer.
    val secondary = PointerButtons(isSecondaryPressed = true)
    scene.sendPointerEvent(PointerEventType.Press, Offset(60f, 60f), buttons = secondary, button = PointerButton.Secondary)
    scene.sendPointerEvent(PointerEventType.Release, Offset(60f, 60f), buttons = PointerButtons(), button = PointerButton.Secondary)
    scene.frame()
    scene.frame()
    // Its second item, below the first.
    scene.click(95f, 113f)
    scene.frame()
    // The menu closed: a click where it was reaches the content under it.
    scene.click(95f, 113f)
    scene.frame()
    println("done")
    scene.dispose()
}
