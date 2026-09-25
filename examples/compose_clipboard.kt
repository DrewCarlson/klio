// The clipboard as Compose Desktop has it. A composition reaches the system
// clipboard through LocalClipboard, whose entries wrap klio.datatransfer
// transferables (java.awt.datatransfer's types, under klio's name), and
// through the deprecated LocalClipboardManager, which reads and writes its
// text. While no other application changes the clipboard, the transferable
// the program put there is the one it reads back, and its owner is told when
// other contents replace it. An entry that is not a transferable empties the
// clipboard.
//
// The tests run it with KLIO_CLIPBOARD=private, a clipboard of the program's
// own; run plainly, it copies onto the host's clipboard. With
// KLIO_CLIPBOARD=none there is no clipboard, as on a headless desktop.
@file:OptIn(ExperimentalComposeUiApi::class)
@file:Suppress("DEPRECATION")

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.asAwtTransferable
import androidx.compose.ui.platform.awtClipboard
import androidx.compose.ui.text.AnnotatedString
import klio.datatransfer.*

// A note that knows when it is no longer on the clipboard.
class Note(private val text: String) : Transferable, ClipboardOwner {
    var lost = 0

    override fun getTransferDataFlavors(): Array<DataFlavor> = arrayOf(DataFlavor.stringFlavor)

    override fun isDataFlavorSupported(flavor: DataFlavor): Boolean = flavor == DataFlavor.stringFlavor

    override fun getTransferData(flavor: DataFlavor): Any {
        if (flavor == DataFlavor.stringFlavor) return text
        throw UnsupportedFlavorException(flavor)
    }

    override fun lostOwnership(clipboard: Clipboard?, contents: Transferable?) {
        lost++
    }
}

fun textOf(t: Transferable?): Any? =
    if (t != null && t.isDataFlavorSupported(DataFlavor.stringFlavor)) t.getTransferData(DataFlavor.stringFlavor) else null

val note = Note("a note")

fun main() {
    val scene = KlioComposeScene(100, 40)
    scene.setContent {
        val clipboard = LocalClipboard.current
        val manager = LocalClipboardManager.current
        LaunchedEffect(Unit) {
            val system = clipboard.awtClipboard
            println("system clipboard: " + (system != null))
            if (system == null) {
                println("entry: " + clipboard.getClipEntry())
                return@LaunchedEffect
            }

            clipboard.setClipEntry(ClipEntry(note))
            val entry = clipboard.getClipEntry()
            println("the same transferable: " + (entry?.asAwtTransferable === note))
            println("text: " + textOf(entry?.asAwtTransferable))
            println("flavors: " + system.availableDataFlavors.size)
            println("has text: " + system.isDataFlavorAvailable(DataFlavor.stringFlavor))

            clipboard.setClipEntry(ClipEntry(StringSelection("a selection")))
            println("read back: " + system.getData(DataFlavor.stringFlavor))
            println("manager text: " + manager.getText())

            clipboard.setClipEntry(ClipEntry(AnnotatedString("not a transferable")))
            println("after a plain entry: " + clipboard.getClipEntry())
            println("has text: " + system.isDataFlavorAvailable(DataFlavor.stringFlavor))
            println("manager has text: " + manager.hasText())
            try {
                system.getData(DataFlavor.stringFlavor)
            } catch (e: UnsupportedFlavorException) {
                println("no text flavor: " + e.message)
            }

            manager.setText(AnnotatedString("from the manager"))
            println("manager text: " + manager.getText())
            println("entry text: " + textOf(clipboard.getClipEntry()?.asAwtTransferable))

            clipboard.setClipEntry(null)
            println("after a null entry: " + clipboard.getClipEntry())
        }
    }
    scene.frame()
    scene.frame()
    println("the note lost the clipboard: " + note.lost)
    scene.dispose()
}
