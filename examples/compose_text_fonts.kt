// corpus: skia
// ui-text's fonts: a FontFamily of a font loaded from its bytes (the Noto Sans
// Mono subset klio bundles, read with kotlinx-io) lays out text with that
// font's metrics, a span of it inside default-family text shapes with it,
// and a weight the family lacks falls back to its closest font. The sizes and
// baselines are the ones Compose Desktop 1.12.0 lays out.
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.layout.Column
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.platform.Font
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.sp
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.readByteArray

fun main() {
    val bytes = SystemFileSystem.source(Path("src/compose_ui/fonts/NotoSansMono-klio.ttf")).buffered().readByteArray()
    val mono = FontFamily(Font("NotoSansMono-klio", bytes))
    val results = sortedMapOf<String, TextLayoutResult>()
    val scene = KlioComposeScene(400, 300)
    scene.setContent {
        Column {
            BasicText("Hello, World", style = TextStyle(fontFamily = mono, fontSize = 16.sp), onTextLayout = { results["loaded 16sp"] = it })
            BasicText("Hello, World", style = TextStyle(fontFamily = mono, fontSize = 32.sp), onTextLayout = { results["loaded 32sp"] = it })
            BasicText("Hello, World", style = TextStyle(fontFamily = mono, fontSize = 16.sp, fontWeight = FontWeight.Bold), onTextLayout = { results["loaded bold"] = it })
            BasicText(
                buildAnnotatedString {
                    withStyle(SpanStyle(fontFamily = mono)) { append("iiii") }
                    withStyle(SpanStyle(fontFamily = mono, fontSize = 24.sp)) { append("WWWW") }
                },
                style = TextStyle(fontSize = 16.sp),
                onTextLayout = { results["spans"] = it },
            )
            BasicText(
                "one two three four five six seven eight nine ten",
                style = TextStyle(fontFamily = mono, fontSize = 16.sp),
                onTextLayout = { results["wrapped"] = it },
            )
        }
    }
    scene.frame()
    for ((name, r) in results) {
        println("$name: size=${r.size} baseline=${r.firstBaseline} lines=${r.lineCount}")
    }
    val wrapped = results.getValue("wrapped")
    println("wrapped line ends: " + (0 until wrapped.lineCount).map { wrapped.getLineEnd(it) })
    println("wrapped offset at (100, 30): " + wrapped.getOffsetForPosition(androidx.compose.ui.geometry.Offset(100f, 30f)))
    scene.dispose()
}
