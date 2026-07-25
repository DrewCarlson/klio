// A NON-inline `@Composable` function that invokes a `Scope.() -> Unit`
// composable lambda parameter with an explicit receiver. The lowering is
// correct — `CallValueWithThis <content> receiver=<scope> (n=2)` with the
// threaded `$composer`/`$changed` as the two arguments — but the runtime
// invocation of the memo-wrapped `ComposableLambdaImpl` selects the wrong
// `invoke` arity, so the scope lands in the `Composer` parameter and the call
// fails as `virtual method slot is not linked for receiver class`
// (`Composer.startRestartGroup` dispatched on the scope object).
//
// `Column { … }` does not hit this because `Column` is `inline`, so its body is
// spliced rather than invoked as a value. This is the shape reached through
// `Card` -> `Column(content = content)` -> the user's `Card { Text(…) }` lambda.
import androidx.compose.runtime.Composable
import androidx.compose.ui.klio.renderComposeToPng

interface MyScope

object MyScopeInstance : MyScope

@Composable
fun Leaf(tag: String) {
    println("leaf $tag")
}

@Composable
fun Holder(content: @Composable MyScope.() -> Unit) {
    MyScopeInstance.content()
}

fun main() {
    renderComposeToPng(32, 32, 1f, "/tmp/klio_recv_lambda.png") { Holder { Leaf("a") } }
    println("receiver lambda ok")
}
