// klio's replacement for Composition.kt / Recomposer.kt (synchronous core).
//
// A `Composition` owns a `KlioComposer` and runs the content lambda against it,
// pushing the composer onto the interpreter's implicit-composer stack for the
// duration so every `@Composable` call inside resolves `currentComposer` to it.
// The `Recomposer` is the parent that owns the set of compositions and drives
// recomposition. The async frame-clock loop is a later phase; here recomposition
// is an explicit `recompose()` call.

package androidx.compose.runtime

public interface Composition {
    /** True if a state write has invalidated content not yet recomposed. */
    public val hasInvalidations: Boolean

    /** True once [dispose] has run. */
    public val isDisposed: Boolean

    /** Set (or replace) the composable content and compose it once. */
    public fun setContent(content: @Composable () -> Unit)

    /** Tear down the composition, forgetting its slots. */
    public fun dispose()
}

public class Recomposer {
    private val compositions: ArrayList<KlioComposition> = ArrayList()

    internal fun registerComposition(composition: KlioComposition) {
        compositions.add(composition)
    }

    internal fun unregisterComposition(composition: KlioComposition) {
        compositions.remove(composition)
    }

    /** True if any registered composition has pending invalidations. */
    public val hasPendingWork: Boolean
        get() {
            for (c in compositions) if (c.hasInvalidations) return true
            return false
        }

    /** Recompose every registered composition that has pending invalidations. */
    public fun recompose() {
        for (c in compositions.toList()) {
            if (c.hasInvalidations) c.recompose()
        }
    }
}

internal class KlioComposition(private val parent: Recomposer) : Composition {
    val composer: KlioComposer = KlioComposer()
    private var content: (@Composable () -> Unit)? = null
    private var disposed: Boolean = false
    private var writeObserverHandle: (() -> Unit)? = null

    init {
        parent.registerComposition(this)
    }

    override val isDisposed: Boolean
        get() = disposed

    override val hasInvalidations: Boolean
        get() = composer.hasInvalidations

    private fun ensureWriteObserver() {
        if (writeObserverHandle == null) {
            writeObserverHandle = StateObservation.registerWriteObserver { state ->
                composer.invalidate(state)
            }
        }
    }

    override fun setContent(content: @Composable () -> Unit) {
        check(!disposed) { "setContent on a disposed Composition" }
        ensureWriteObserver()
        this.content = content
        composer.beginInitialPass()
        composeContent()
    }

    private fun composeContent() {
        val body = content ?: return
        // Reads during composition subscribe the running composable's group;
        // a later write to one of those state objects invalidates that group.
        StateObservation.observe({ state -> composer.subscribeRead(state) }) {
            __compose_pushComposer(composer)
            try {
                composer.beginCompose()
                body()
                composer.endCompose()
            } finally {
                __compose_popComposer()
            }
        }
    }

    internal fun recompose() {
        if (disposed) return
        composer.beginRecomposePass()
        composeContent()
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        content = null
        writeObserverHandle?.invoke()
        writeObserverHandle = null
        parent.unregisterComposition(this)
    }
}

/** Create a composition whose recomposition is driven by [parent]. */
public fun Composition(parent: Recomposer): Composition = KlioComposition(parent)
