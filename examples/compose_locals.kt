// Compose runtime: CompositionLocal — a value provided to a subtree, with
// nested overrides and a default outside any provider.
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.CompositionLocalProvider

val LocalName = compositionLocalOf { "default" }

@Composable
fun Greeting() {
    println("hello, ${LocalName.current}")
}

@Composable
fun App() {
    Greeting()
    CompositionLocalProvider(LocalName provides "Alice") {
        Greeting()
        CompositionLocalProvider(LocalName provides "Bob") {
            Greeting()
        }
        Greeting()
    }
    Greeting()
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    composition.setContent { App() }
}
