// On-screen Material 3 scene for the mobile app hosts (iOS + Android). Drives
// the real windowing path like window_scene.kt, but the tree is a Material 3
// surface: MaterialTheme supplies the color/typography CompositionLocals, a
// Scaffold lays out a TopAppBar over a body, and a Button mutates state so a tap
// recomposes the count. This exercises theming, ripple, foundation layout,
// state/recomposition and text through the full androidx compose stack.
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

@OptIn(ExperimentalMaterial3Api::class)
fun main() {
    application {
        Window(onCloseRequest = ::exitApplication, title = "klio M3", width = 390, height = 844) {
            MaterialTheme(colorScheme = darkColorScheme()) {
                var count by remember { mutableStateOf(0) }
                Scaffold(
                    topBar = { TopAppBar(title = { Text("Material 3 · klio") }) },
                ) { padding ->
                    Column(
                        Modifier.fillMaxSize().padding(padding).padding(16.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Card {
                            Text(
                                "Tap count: $count",
                                Modifier.padding(16.dp),
                                style = MaterialTheme.typography.headlineSmall,
                            )
                        }
                        Button(onClick = { count++ }) {
                            Text("Increment")
                        }
                    }
                }
            }
        }
    }
}
