// A window's drag and drop, as Compose Desktop's AwtDragAndDropManager runs
// it over AWT's: a drag from another application (or from the window itself)
// over the window reaches the scene's root drag-and-drop node, which decides
// whether the window takes it, and a dragAndDropSource in the content starts
// a platform drag carrying its transferable, drawn with its decoration. The
// shim answers the platform with the program's latest acceptance, which each
// move of the drag refreshes.

package androidx.compose.ui.window

import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.draganddrop.DragAndDropEvent
import androidx.compose.ui.draganddrop.DragAndDropTransferAction
import androidx.compose.ui.draganddrop.DragAndDropTransferData
import androidx.compose.ui.draganddrop.KlioDragAndDropTransferable
import androidx.compose.ui.draganddrop.KlioDropEvent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asSkiaBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.platform.PlatformDragAndDropManager
import androidx.compose.ui.platform.PlatformDragAndDropSource
import androidx.compose.ui.scene.ComposeScene
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import klio.datatransfer.DataFlavor
import klio.datatransfer.Transferable
import klio.datatransfer.UnsupportedFlavorException
import kotlin.math.roundToInt
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image

private const val DND_ENTER = 1
private const val DND_OVER = 2
private const val DND_EXIT = 3
private const val DND_DROP = 4
private const val DND_SOURCE_ENDED = 5

private const val ACTION_COPY = 1
private const val ACTION_MOVE = 2
private const val ACTION_LINK = 4

@OptIn(ExperimentalComposeUiApi::class, InternalComposeUiApi::class)
internal class KlioWindowDragAndDrop(private val handle: Long) : PlatformDragAndDropManager {
    /** The window's scene, whose root drag-and-drop node takes the drags over it. */
    var scene: ComposeScene? = null

    /** What the drag the window started asked to hear when it ends. */
    private var onTransferCompleted: ((DragAndDropTransferAction?) -> Unit)? = null

    override val isRequestDragAndDropTransferRequired: Boolean
        get() = true

    override fun requestDragAndDropTransfer(source: PlatformDragAndDropSource, offset: Offset) {
        var isTransferStarted = false
        val scope = object : PlatformDragAndDropSource.StartTransferScope {
            override fun startDragAndDropTransfer(
                transferData: DragAndDropTransferData,
                decorationSize: Size,
                drawDragDecoration: DrawScope.() -> Unit,
            ): Boolean {
                isTransferStarted = startDrag(transferData, decorationSize, drawDragDecoration)
                return isTransferStarted
            }
        }
        with(source) {
            scope.startDragAndDropTransfer(offset) { isTransferStarted }
        }
    }

    private fun startDrag(data: DragAndDropTransferData, size: Size, draw: DrawScope.() -> Unit): Boolean {
        val transferable = (data.transferable as? KlioDragAndDropTransferable)?.toTransferable() ?: return false
        val width = size.width.roundToInt().coerceAtLeast(1)
        val height = size.height.roundToInt().coerceAtLeast(1)
        val image = ImageBitmap(width, height)
        CanvasDrawScope().draw(Density(1f), LayoutDirection.Ltr, Canvas(image), size, draw)
        val png = Image.makeFromBitmap(image.asSkiaBitmap()).encodeToData(EncodedImageFormat.PNG)?.bytes ?: ByteArray(0)
        val actions = data.supportedActions.fold(0) { bits, action -> bits or bitOf(action) }
        onTransferCompleted = data.onTransferCompleted
        val started = __composeui_winDragStart(
            handle,
            payloadOf(transferable),
            png,
            data.dragDecorationOffset.x.roundToInt(),
            data.dragDecorationOffset.y.roundToInt(),
            actions,
        )
        if (!started) onTransferCompleted = null
        return started
    }

    /**
     * A drag over the window, as the shim reports it: [kind] (enter, over,
     * exit, drop, or the end of the window's own drag), where it is, the
     * actions it offers (or, when it ended, the one taken) and its [payload].
     * An enter, move or drop is answered with the action the window takes;
     * the shim reads one left unanswered as refused.
     */
    fun onEvent(kind: Int, x: Float, y: Float, actions: Int, payload: String) {
        if (kind == DND_SOURCE_ENDED) {
            val done = onTransferCompleted
            onTransferCompleted = null
            done?.invoke(actionOf(actions))
            return
        }
        val root = scene?.rootDragAndDropNode ?: return
        val action = actionOf(actions)
        val event = DragAndDropEvent(
            action = if (kind == DND_EXIT) null else action,
            nativeEvent = KlioDropEvent(transferableOf(payload)),
            positionInRootImpl = if (kind == DND_EXIT) Offset.Zero else Offset(x, y),
        )
        when (kind) {
            DND_ENTER -> {
                // There is no drag-start event on the desktop either: it
                // starts as the drag enters and ends as it leaves or drops.
                val accepted = root.acceptDragAndDropTransfer(event)
                if (accepted) {
                    root.onStarted(event)
                    root.onEntered(event)
                }
                __composeui_winDndAccept(handle, if (accepted) bitOf(action) else 0)
            }
            DND_OVER -> {
                root.onMoved(event)
                __composeui_winDndAccept(handle, if (root.hasEligibleDropTarget) bitOf(action) else 0)
            }
            DND_EXIT -> {
                root.onExited(event)
                root.onEnded(event)
            }
            DND_DROP -> {
                // The drop's result goes back to the drag's source, as
                // AWT's dropComplete sends it.
                val dropped = root.onDrop(event)
                __composeui_winDndAccept(handle, if (dropped) bitOf(action) else 0)
                root.onEnded(event)
            }
        }
    }

    // The action a drag takes of those it offers, as a desktop drag takes its
    // default one: a copy where it offers one (the platform offers the one
    // the user chose, where it chooses).
    private fun actionOf(bits: Int): DragAndDropTransferAction? = when {
        bits and ACTION_COPY != 0 -> DragAndDropTransferAction.Copy
        bits and ACTION_MOVE != 0 -> DragAndDropTransferAction.Move
        bits and ACTION_LINK != 0 -> DragAndDropTransferAction.Link
        else -> null
    }

    private fun bitOf(action: DragAndDropTransferAction?): Int = when (action) {
        DragAndDropTransferAction.Copy -> ACTION_COPY
        DragAndDropTransferAction.Move -> ACTION_MOVE
        DragAndDropTransferAction.Link -> ACTION_LINK
        else -> 0
    }
}

// The data a drag carries, as the shim passes it: a line `F<path>` per file,
// then `T` and the text.
private fun payloadOf(transferable: Transferable): String {
    val out = StringBuilder()
    if (transferable.isDataFlavorSupported(DataFlavor.javaFileListFlavor)) {
        for (f in transferable.getTransferData(DataFlavor.javaFileListFlavor) as List<*>) {
            if (f is String) out.append('F').append(f).append('\n')
        }
    }
    if (transferable.isDataFlavorSupported(DataFlavor.stringFlavor)) {
        out.append('T').append(transferable.getTransferData(DataFlavor.stringFlavor) as String)
    }
    return out.toString()
}

private fun transferableOf(payload: String): Transferable {
    val files = mutableListOf<String>()
    var text: String? = null
    var i = 0
    while (i < payload.length) {
        if (payload[i] == 'T') {
            text = payload.substring(i + 1)
            break
        }
        val end = payload.indexOf('\n', i).let { if (it < 0) payload.length else it }
        if (payload[i] == 'F') files.add(payload.substring(i + 1, end))
        i = end + 1
    }
    return KlioDropTransferable(files.takeIf { it.isNotEmpty() }, text)
}

/** What a drag from the platform carries: its files, its text. */
private class KlioDropTransferable(private val files: List<String>?, private val text: String?) : Transferable {
    override fun getTransferDataFlavors(): Array<out DataFlavor?> = listOfNotNull(
        if (files != null) DataFlavor.javaFileListFlavor else null,
        if (text != null) DataFlavor.stringFlavor else null,
    ).toTypedArray()

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean =
        (flavor == DataFlavor.javaFileListFlavor && files != null) || (flavor == DataFlavor.stringFlavor && text != null)

    override fun getTransferData(flavor: DataFlavor): Any = when {
        flavor == DataFlavor.javaFileListFlavor && files != null -> files
        flavor == DataFlavor.stringFlavor && text != null -> text
        else -> throw UnsupportedFlavorException(flavor)
    }
}

/**
 * Starts a platform drag from the window carrying [payload], shown as the
 * [png] decoration held at ([offsetX], [offsetY]), offering [actions]; false
 * when it cannot start.
 */
internal fun __composeui_winDragStart(
    handle: Long,
    payload: String,
    png: ByteArray,
    offsetX: Int,
    offsetY: Int,
    actions: Int,
): Boolean = error("intrinsic androidx.compose.ui.window.__composeui_winDragStart not installed")

/** The action the window takes of the drag event it handled (0 when it takes none). */
internal fun __composeui_winDndAccept(handle: Long, action: Int): Unit =
    error("intrinsic androidx.compose.ui.window.__composeui_winDndAccept not installed")
