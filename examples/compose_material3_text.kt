// material3 Text over the real text stack: upstream material3's Text
// composable routes through foundation's BasicText into the real
// androidx.compose.ui.text engine (skparagraph-backed when a Skia library
// is present, the deterministic headless engine otherwise). MaterialTheme
// typography drives real measured metrics: the layout results reported by
// onTextLayout order strictly by the typography scale in both engines.

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.klio.renderComposeToPng
import androidx.compose.ui.text.TextLayoutResult

var hl: TextLayoutResult? = null
var body: TextLayoutResult? = null
var label: TextLayoutResult? = null

fun main() {
    renderComposeToPng(360, 160, 1f, "/tmp/klio_compose_material3_text.png") {
        MaterialTheme {
            Column {
                Text("Headline", style = MaterialTheme.typography.headlineLarge, onTextLayout = { hl = it })
                Text("Body text", style = MaterialTheme.typography.bodyMedium, onTextLayout = { body = it })
                Text("Label", style = MaterialTheme.typography.labelSmall, onTextLayout = { label = it })
            }
        }
    }
    val h = hl!!.size.height
    val b = body!!.size.height
    val l = label!!.size.height
    println("laid out=" + (hl != null && body != null && label != null))
    println("headline taller than body=" + (h > b))
    println("body taller than label=" + (b > l))
    println("single line each=" + (hl!!.lineCount == 1 && body!!.lineCount == 1 && label!!.lineCount == 1))
    println("headline text=" + hl!!.layoutInput.text.text)
}
