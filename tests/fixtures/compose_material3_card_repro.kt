// `Card` calls `colors.containerColor(enabled = true)`, where
// `CardColors.containerColor(Boolean)` is `@Stable` — not `@Composable` — while
// an unrelated colors type declares a `@Composable containerColor` of the same
// name and arity. The lowering pass appends its generated `$composer`/`$changed`
// pair from a name-keyed oracle, so the pair lands on the non-composable member
// too; the member walk must ignore it rather than reject the candidate and fall
// back to the same-named `val containerColor` property, which then fails as
// `call_member 'invoke' on Color`.
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.ui.klio.renderComposeToPng

fun main() {
    renderComposeToPng(390, 844, 1f, "/tmp/klio_m3_card.png") {
        MaterialTheme(colorScheme = darkColorScheme()) {
            Card { Text("card") }
        }
    }
    println("card ok")
}
