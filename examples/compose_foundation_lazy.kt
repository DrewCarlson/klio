// The real androidx.compose.foundation LazyColumn through the real UI engine:
// SubcomposeLayout drives per-item subcomposition (only visible indices
// compose), items measure through the real text stack, and LazyListState
// carries the scroll position (initialFirstVisibleItemIndex shifts the
// window). The engine facts printed below are deterministic headless; with a
// Skia backend the same run also rasterizes the list to a PNG.

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.Modifier
import androidx.compose.ui.klio.renderComposeToPng
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp

var composed = 0
var stateRef: LazyListState? = null

fun main() {
    renderComposeToPng(200, 120, 1f, "/tmp/klio_compose_foundation_lazy.png") {
        val state = rememberLazyListState(initialFirstVisibleItemIndex = 10)
        stateRef = state
        LazyColumn(Modifier.fillMaxSize(), state = state) {
            items(30) { i ->
                composed += 1
                BasicText("row " + i, style = TextStyle(fontSize = 14.sp))
            }
        }
    }
    val st = stateRef!!
    println("items composed=" + composed + " of 30")
    println("first visible=" + st.firstVisibleItemIndex)
    val info = st.layoutInfo
    println("visible count=" + info.visibleItemsInfo.size)
    println("first visible key=" + info.visibleItemsInfo[0].index)
    println("total=" + info.totalItemsCount)
}
