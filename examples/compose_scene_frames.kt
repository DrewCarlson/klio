// Each frame of a KlioComposeScene starts by applying the state written since
// the last frame, as a desktop frame does. A value the program writes between
// frames, or one a click handler writes, recomposes the content that reads it
// in that same frame. A frame with nothing written recomposes nothing.
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.klio.KlioComposeScene

fun main() {
    var count by mutableStateOf(0)
    val scene = KlioComposeScene(100, 100)
    scene.setContent {
        println("compose count=$count")
        Box(Modifier.fillMaxSize().clickable { count += 10 })
    }
    count = 1
    println("frame after a write")
    scene.frame()
    println("click")
    scene.click(50f, 50f)
    println("frame with nothing written")
    scene.frame()
    scene.dispose()
}
