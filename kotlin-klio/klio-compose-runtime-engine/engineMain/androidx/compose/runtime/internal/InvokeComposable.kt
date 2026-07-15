package androidx.compose.runtime.internal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composer

// The compose lowering plugin lowers a `@Composable () -> Unit` to a
// `Function2<Composer, Int, Unit>`; the engine drives the root content through
// this intrinsic, passing the composer and an initial changed flag.
//
// The root content is wrapped in a `ComposableLambdaImpl` so its `invoke` opens
// a `startRestartGroup`, establishing the root recompose scope that
// `Composition.recordReadOf` attributes state reads to. Without it the content
// reads state with no current recompose scope, the read is never marked
// `ReaderKind.Composition`, and a later `MutableState` write is dropped by the
// recomposer's apply observer — so no recomposition happens (CompositionTests.
// simpleChanges' `expectChanges()` sees no changes). With it, a write DOES
// invalidate and recompose. On recompose the scope re-invokes itself via
// `endRestartGroup()?.updateScope(this::invoke)`.
private const val rootContentKey = 0x10a7f001

internal actual fun invokeComposable(composer: Composer, composable: @Composable () -> Unit) {
    ComposableLambdaImpl(rootContentKey, true, composable).invoke(composer, 1)
}
