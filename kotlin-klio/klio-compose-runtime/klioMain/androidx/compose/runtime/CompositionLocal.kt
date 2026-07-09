// klio's CompositionLocal — subtree-scoped values resolved through the composer.
//
// `compositionLocalOf { default }` creates a local; `CompositionLocalProvider(
// Local provides value) { … }` provides a value for the enclosed composables;
// `Local.current` reads the nearest provided value (or the default). The
// composer keeps a stack of provider layers pushed/popped around the provider's
// content, so `consume` walks outward to the nearest binding. (Reactive
// re-reading on a changed provided value is layered on with the snapshot
// observable path later; providing + reading is exact.)

package androidx.compose.runtime

public sealed class CompositionLocal<T>(internal val defaultFactory: () -> T) {
    @Suppress("UNCHECKED_CAST")
    public val current: T
        @Composable
        get() = requireComposer().consume(this) as T
}

public class ProvidableCompositionLocal<T> internal constructor(defaultFactory: () -> T) :
    CompositionLocal<T>(defaultFactory) {

    /** Bind this local to [value] for a [CompositionLocalProvider] subtree. */
    public infix fun provides(value: T): ProvidedValue<T> = ProvidedValue(this, value)
}

public class ProvidedValue<T> internal constructor(
    public val compositionLocal: CompositionLocal<T>,
    public val value: T,
)

/** A CompositionLocal whose value is read reactively (re-read on change).
 *
 * The [policy] parameter matches the upstream signature so consumers that pass
 * an explicit mutation policy (`compositionLocalOf(structuralEqualityPolicy())
 * { … }`, as material3's `LocalTextStyle` does) bind correctly; klio's composer
 * reads the provided value reactively without the policy-based change dedup, so
 * the policy is accepted and ignored. */
public fun <T> compositionLocalOf(
    policy: SnapshotMutationPolicy<T> = structuralEqualityPolicy(),
    defaultFactory: () -> T,
): ProvidableCompositionLocal<T> = ProvidableCompositionLocal(defaultFactory)

/** A CompositionLocal whose subtree recomposes wholesale when its value changes. */
public fun <T> staticCompositionLocalOf(defaultFactory: () -> T): ProvidableCompositionLocal<T> =
    ProvidableCompositionLocal(defaultFactory)

/** Provide [values] to [content]; each binding shadows any outer one. */
@Composable
public fun CompositionLocalProvider(vararg values: ProvidedValue<*>, content: @Composable () -> Unit) {
    val c = requireComposer()
    c.startProviders(values)
    try {
        content()
    } finally {
        c.endProviders()
    }
}
