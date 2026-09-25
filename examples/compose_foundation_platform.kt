// The platform pieces of androidx.compose.foundation that klio supplies. A
// MutatorMutex keeps its current mutator in an atomic reference: a mutation of
// higher priority cancels the one running, waits for it to let go, then runs.
// A composition reaches the clipboard through LocalClipboard; a ClipEntry of
// an AnnotatedString, which is not a transferable, empties it, as on the
// desktop (compose_clipboard copies text).
import androidx.compose.foundation.MutatePriority
import androidx.compose.foundation.MutatorMutex
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.text.AnnotatedString
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

@OptIn(ExperimentalComposeUiApi::class)
fun main() {
    runBlocking {
        val mutex = MutatorMutex()
        val first = launch {
            try {
                mutex.mutate(MutatePriority.Default) { awaitCancellation() }
            } catch (e: CancellationException) {
                println("default mutator cancelled")
            }
        }
        yield()
        println("busy: " + !mutex.tryMutate { })
        mutex.mutate(MutatePriority.UserInput) { println("user input mutator ran") }
        first.join()
        println("free: " + mutex.tryMutate { })
    }

    val scene = KlioComposeScene(100, 40)
    scene.setContent {
        val clipboard = LocalClipboard.current
        LaunchedEffect(Unit) {
            clipboard.setClipEntry(ClipEntry(AnnotatedString("copied text")))
            val entry = clipboard.getClipEntry()
            println("clip: " + (entry?.nativeClipEntry as? AnnotatedString)?.text)
        }
    }
    scene.frame()
    scene.dispose()
}
