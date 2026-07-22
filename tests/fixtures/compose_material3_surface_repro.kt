import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.klio.renderComposeToPng

fun main() {
    renderComposeToPng(390, 844, 1f, "/tmp/klio_m3_surface.png") {
        MaterialTheme(colorScheme = darkColorScheme()) {
            Surface {}
        }
    }
}
