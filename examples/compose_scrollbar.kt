// corpus: skia
// The desktop scrollbars of foundation's skiko source set: a VerticalScrollbar
// attached through rememberScrollbarAdapter to a LazyColumn's state draws its
// thumb in proportion to the visible part of the content, and moves it as the
// list scrolls. A ScrollbarStyle from LocalScrollbarStyle colors it. The thumb
// is read back from the rendered frame's pixels.
import androidx.compose.foundation.LocalScrollbarStyle
import androidx.compose.foundation.VerticalScrollbar
import androidx.compose.foundation.background
import androidx.compose.foundation.defaultScrollbarStyle
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.rememberScrollbarAdapter
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.runBlocking

/** The rows of the scrollbar's column (x = 195) the thumb covers, as a range. */
fun PixelMap.thumbRows(): IntRange? {
    val rows = (0 until height).filter { this[195, it] == Color.Red }
    return if (rows.isEmpty()) null else rows.first()..rows.last()
}

fun main() {
    val state = LazyListState()
    // A 200 px viewport over 20 rows of 50 px: the thumb spans a fifth of it.
    val scene = KlioComposeScene(200, 200)
    scene.setContent {
        CompositionLocalProvider(
            LocalScrollbarStyle provides defaultScrollbarStyle().copy(
                unhoverColor = Color.Red,
                hoverColor = Color.Red,
                thickness = 10.dp,
            ),
        ) {
            Box(Modifier.fillMaxSize().background(Color.White)) {
                LazyColumn(Modifier.fillMaxSize(), state = state) {
                    items(20) { Box(Modifier.height(50.dp)) }
                }
                VerticalScrollbar(
                    adapter = rememberScrollbarAdapter(state),
                    modifier = Modifier.align(Alignment.CenterEnd).fillMaxHeight(),
                )
            }
        }
    }
    val atTop = scene.render().toPixelMap().thumbRows()
    println("thumb at the top: $atTop")
    runBlocking { state.scrollToItem(10) }
    val halfway = scene.render().toPixelMap().thumbRows()
    println("thumb after scrolling to row 10: $halfway")
    runBlocking { state.scrollToItem(16) }
    val atEnd = scene.render().toPixelMap().thumbRows()
    println("thumb at the end: $atEnd")
    scene.dispose()
}
