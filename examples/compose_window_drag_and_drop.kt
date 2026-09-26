// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Drag and drop in a window, as on Compose Desktop: text and files another
// application drops reach a dragAndDropTarget with their data, and a drag
// from a dragAndDropSource carries its transferable to a target (here in
// the same window) and hears the action the drop took. The drops and the
// drag come from compose_window_drag_and_drop.input, scripted into the
// window ($KLIO_WIN_INPUT).
@file:OptIn(ExperimentalFoundationApi::class, ExperimentalComposeUiApi::class)

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.draganddrop.dragAndDropSource
import androidx.compose.foundation.draganddrop.dragAndDropTarget
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.remember
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTarget
import androidx.compose.ui.draganddrop.DragAndDropTransferAction
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.DragAndDropTransferable
import androidx.compose.ui.draganddrop.DragData
import androidx.compose.ui.draganddrop.dragData
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import klio.datatransfer.StringSelection

fun main() {
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "drag and drop") {
            val target = remember {
                object : DragAndDropTarget {
                    override fun onEntered(event: DragAndDropEvent) = println("entered")
                    override fun onExited(event: DragAndDropEvent) = println("exited")
                    override fun onDrop(event: DragAndDropEvent): Boolean {
                        when (val data = event.dragData()) {
                            is DragData.Text -> println("dropped text: ${data.readText()}")
                            is DragData.FilesList -> println("dropped files: ${data.readFiles()}")
                            else -> println("dropped something else")
                        }
                        return true
                    }
                }
            }
            Column {
                Box(
                    Modifier.size(200.dp, 60.dp).background(Color.Gray).dragAndDropSource { _ ->
                        DragAndDropTransferData(
                            transferable = DragAndDropTransferable(StringSelection("dragged text")),
                            supportedActions = listOf(DragAndDropTransferAction.Copy, DragAndDropTransferAction.Move),
                            onTransferCompleted = { action -> println("transfer completed: $action") },
                        )
                    }
                )
                Box(
                    Modifier.size(200.dp, 60.dp).background(Color.LightGray)
                        .dragAndDropTarget(shouldStartDragAndDrop = { true }, target = target)
                )
            }
        }
    }
    println("application ended")
}
