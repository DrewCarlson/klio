// klio's synchronous effect handlers.
//
// `SideEffect` runs its block after every successful (re)composition of the
// enclosing composable. `DisposableEffect` runs its block on first composition
// (or when a key changes), and runs the `onDispose` block when a key changes or
// the composition is disposed. The coroutine-driven effects (`LaunchedEffect`,
// `rememberCoroutineScope`, `produceState`) build on the coroutines pack and
// land in a later phase.

package androidx.compose.runtime

// SideEffect / DisposableEffect are non-restartable: they execute as part of
// their caller's group (their slots live in the caller, they run whenever the
// caller (re)composes), never as their own skippable scope. In klio that means
// plain functions reading `currentComposer` — not `@Composable`-bracketed calls,
// which would get their own group and be skipped on a recompose that did not
// invalidate them.

/** Run [effect] after the current composition completes (every time it runs). */
public fun SideEffect(effect: () -> Unit) {
    (requireComposer() as KlioComposer).recordSideEffect(effect)
}

public class DisposableEffectScope {
    /** Declare the cleanup to run on key change or composition dispose. */
    public fun onDispose(onDisposeEffect: () -> Unit): DisposableEffectResult =
        DisposableEffectResult(onDisposeEffect)
}

public class DisposableEffectResult internal constructor(
    internal val onDispose: () -> Unit,
)

private val InternalDisposableEffectScope = DisposableEffectScope()

/** Effect tied to [key1]: (re)runs when [key1] changes; disposes on change/dispose. */
public fun DisposableEffect(key1: Any?, effect: DisposableEffectScope.() -> DisposableEffectResult) {
    val c = requireComposer() as KlioComposer
    val keyChanged = c.changed(key1)
    val prev = c.rememberedValue()
    if (keyChanged || prev === Composer.Empty) {
        if (prev is DisposableEffectResult) {
            c.removeDisposer(prev)
            prev.onDispose()
        }
        val result = InternalDisposableEffectScope.effect()
        c.addDisposer(result)
        c.updateRememberedValue(result)
    }
}

/** Effect re-run whenever any of [keys] changes (upstream's vararg form). */
public fun DisposableEffect(
    vararg keys: Any?,
    effect: DisposableEffectScope.() -> DisposableEffectResult,
) {
    val c = requireComposer() as KlioComposer
    var keyChanged = false
    for (k in keys) {
        keyChanged = c.changed(k) || keyChanged
    }
    val prev = c.rememberedValue()
    if (keyChanged || prev === Composer.Empty) {
        if (prev is DisposableEffectResult) {
            c.removeDisposer(prev)
            prev.onDispose()
        }
        val result = InternalDisposableEffectScope.effect()
        c.addDisposer(result)
        c.updateRememberedValue(result)
    }
}

/** Effect tied to [key1]+[key2]. */
public fun DisposableEffect(
    key1: Any?,
    key2: Any?,
    effect: DisposableEffectScope.() -> DisposableEffectResult,
) {
    val c = requireComposer() as KlioComposer
    var keyChanged = c.changed(key1)
    keyChanged = c.changed(key2) || keyChanged
    val prev = c.rememberedValue()
    if (keyChanged || prev === Composer.Empty) {
        if (prev is DisposableEffectResult) {
            c.removeDisposer(prev)
            prev.onDispose()
        }
        val result = InternalDisposableEffectScope.effect()
        c.addDisposer(result)
        c.updateRememberedValue(result)
    }
}
