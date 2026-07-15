package androidx.compose.runtime.internal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composer

// The compose lowering plugin lowers a `@Composable () -> Unit` to a
// `Function2<Composer, Int, Unit>`; the engine drives the root content through
// this intrinsic, passing the composer and an initial changed flag.
@Suppress("UNCHECKED_CAST")
internal actual fun invokeComposable(composer: Composer, composable: @Composable () -> Unit) {
    (composable as Function2<Composer, Int, Unit>).invoke(composer, 1)
}
