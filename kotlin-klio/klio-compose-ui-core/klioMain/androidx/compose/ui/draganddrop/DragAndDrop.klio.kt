// The drag-and-drop types of ui's DragAndDrop.kt, as desktop declares them
// (DragAndDrop.desktop.kt and AwtDragData.kt), over klio.datatransfer in
// place of java.awt.datatransfer: a transfer carries a DragAndDropTransferable
// made from a Transferable and its actions, and an event its action, the
// platform's own event (the Transferable dropped) and where it is in the root.
package androidx.compose.ui.draganddrop

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.painter.Painter
import klio.datatransfer.DataFlavor
import klio.datatransfer.Transferable

actual class DragAndDropTransferData @ExperimentalComposeUiApi constructor(
    @property:ExperimentalComposeUiApi
    val transferable: DragAndDropTransferable,
    @property:ExperimentalComposeUiApi
    val supportedActions: Iterable<DragAndDropTransferAction>,
    @property:ExperimentalComposeUiApi
    val dragDecorationOffset: Offset = Offset.Zero,
    @property:ExperimentalComposeUiApi
    val onTransferCompleted: ((userAction: DragAndDropTransferAction?) -> Unit)? = null,
) {
    init {
        require(supportedActions.firstOrNull() != null) { "supportedActions may not be empty" }
    }
}

@ExperimentalComposeUiApi
interface DragAndDropTransferable

internal interface KlioDragAndDropTransferable : DragAndDropTransferable {
    fun toTransferable(): Transferable
}

/** The [transferable] a drag carries, as the desktop makes one from AWT's. */
@ExperimentalComposeUiApi
fun DragAndDropTransferable(transferable: Transferable): DragAndDropTransferable =
    object : KlioDragAndDropTransferable {
        override fun toTransferable() = transferable
    }

/** A drag over a window from the platform: what it carries. */
internal class KlioDropEvent(val transferable: Transferable)

/** The data a drag carries, as the desktop's event offers AWT's Transferable. */
@ExperimentalComposeUiApi
val DragAndDropEvent.awtTransferable: Transferable
    get() = (nativeEvent as? KlioDropEvent)?.transferable ?: error("Unrecognized drag event: $nativeEvent")

@ExperimentalComposeUiApi
fun DragAndDropEvent.dragData(): DragData = awtTransferable.dragData()

@OptIn(ExperimentalComposeUiApi::class)
internal fun Transferable.dragData(): DragData = when {
    isDataFlavorSupported(DataFlavor.javaFileListFlavor) -> object : DragData.FilesList {
        // A file's URI, as java.io.File.toURI() gives it.
        override fun readFiles(): List<String> =
            (getTransferData(DataFlavor.javaFileListFlavor) as List<*>).filterIsInstance<String>().map {
                val path = it.replace('\\', '/')
                if (path.startsWith("/")) "file:$path" else "file:/$path"
            }
    }
    isDataFlavorSupported(DataFlavor.stringFlavor) -> object : DragData.Text {
        override val bestMimeType: String = DataFlavor.stringFlavor.mimeType
        override fun readText(): String = getTransferData(DataFlavor.stringFlavor) as String
    }
    else -> object : DragData {}
}

@ExperimentalComposeUiApi
class DragAndDropTransferAction private constructor(private val name: String) {
    override fun toString(): String {
        return name
    }

    companion object {
        val Copy = DragAndDropTransferAction("Copy")
        val Move = DragAndDropTransferAction("Move")
        val Link = DragAndDropTransferAction("Link")
    }
}

actual class DragAndDropEvent @ExperimentalComposeUiApi constructor(
    @property:ExperimentalComposeUiApi
    val action: DragAndDropTransferAction?,
    @property:ExperimentalComposeUiApi
    val nativeEvent: Any?,
    internal val positionInRootImpl: Offset
)

@ExperimentalComposeUiApi
interface DragData {
    interface FilesList : DragData {
        fun readFiles(): List<String>
    }

    interface Image : DragData {
        fun readImage(): Painter
    }

    interface Text : DragData {
        val bestMimeType: String
        fun readText(): String
    }
}

internal actual val DragAndDropEvent.positionInRoot: Offset
    get() = positionInRootImpl
