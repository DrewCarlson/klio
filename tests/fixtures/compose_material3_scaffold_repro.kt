import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.klio.renderComposeToPng

@OptIn(ExperimentalMaterial3Api::class)
fun main() {
    val ok = renderComposeToPng(390, 844, 1f, "/tmp/klio_m3_scaffold.png") {
        MaterialTheme(colorScheme = darkColorScheme()) {
            Scaffold(topBar = { TopAppBar(title = { Text("x") }) }) { _ -> }
        }
    }
    println(if (ok) "scaffold ok" else "scaffold draw failed")
}
