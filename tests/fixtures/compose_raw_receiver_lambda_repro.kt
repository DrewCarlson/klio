// A NON-composable function (like `application` in KlioWindow) that stores a
// `Scope.() -> Unit` composable lambda and invokes it with an explicit receiver
// from INSIDE a composition started by a separate content lambda. The lambda is
// a RAW closure (no ComposableLambdaImpl wrap — its binding site is not in a
// composable scope), so the receiver invocation must pass the scope as the
// closure's leading positional slot before the `$composer`/`$changed` pair.
// Getting this wrong shifts every argument left: the composer lands in the
// receiver slot and `$composer` receives the Int dirty flags, which then fails
// far away as `cache`/`startRestartGroup` dispatched on `kotlin.Int`.
import androidx.compose.runtime.Composable
import androidx.compose.ui.klio.renderComposeToPng

interface AppScope {
    fun tag(): String
}

object AppScopeInstance : AppScope {
    override fun tag(): String = "scope"
}

@Composable
fun Leaf(tag: String) {
    println("leaf $tag")
}

fun runApp(content: @Composable AppScope.() -> Unit) {
    renderComposeToPng(32, 32, 1f, "/tmp/klio_raw_recv_lambda.png") {
        AppScopeInstance.content()
    }
}

fun main() {
    runApp { Leaf(tag()) }
    println("raw receiver lambda ok")
}
