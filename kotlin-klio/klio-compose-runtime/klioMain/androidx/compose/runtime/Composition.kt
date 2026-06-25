// klio's replacement for Composition.kt / Recomposer.kt.
//
// A `Composition` owns a `KlioComposer` and runs the content lambda against it,
// pushing the composer onto the interpreter's implicit-composer stack for the
// duration so every `@Composable` call inside resolves `currentComposer` to it.
// The `Recomposer` owns the set of compositions and drives recomposition: either
// synchronously via `recompose()`, or asynchronously via
// `runRecomposeAndApplyChanges()` — a suspend loop, run inside a coroutine driver
// (runBlocking), that wakes on a state-write invalidation and recomposes. Effects
// launch onto the recomposer's coroutine scope, so they suspend/resume correctly
// under the driver instead of running eagerly.

package androidx.compose.runtime

import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel

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

public class Recomposer(
    private val effectContext: CoroutineContext = EmptyCoroutineContext,
) {
    private val compositions: ArrayList<KlioComposition> = ArrayList()

    private val effectJob: Job = Job()

    /** The scope effects (LaunchedEffect / rememberCoroutineScope / produceState)
     * launch onto: the driver's context (so launches dispatch + suspend correctly)
     * under a cancellable job. */
    internal val effectScope: CoroutineScope =
        CoroutineScope(effectContext + effectJob)

    // Conflated wake channel: a write-observer invalidation sends a unit; the
    // async loop receives it and recomposes.
    private val workChannel: Channel<Unit> = Channel(Channel.CONFLATED)
    private var closed: Boolean = false

    internal fun registerComposition(composition: KlioComposition) {
        composition.attachRecomposer(this)
        compositions.add(composition)
    }

    internal fun unregisterComposition(composition: KlioComposition) {
        compositions.remove(composition)
    }

    /** Wake the async recomposition loop (called when a composition is invalidated). */
    internal fun notifyWorkAvailable() {
        if (!closed) workChannel.trySend(Unit)
    }

    /** True if any registered composition has pending invalidations. */
    public val hasPendingWork: Boolean
        get() {
            for (c in compositions) if (c.hasInvalidations) return true
            return false
        }

    /** Recompose every registered composition that has pending invalidations (synchronous). */
    public fun recompose() {
        for (c in compositions.toList()) {
            if (c.hasInvalidations) c.recompose()
        }
    }

    /**
     * Drive recomposition asynchronously until [close]d. Runs inside a coroutine
     * (e.g. `launch { recomposer.runRecomposeAndApplyChanges() }` under a driver):
     * it suspends on the wake channel until a state write invalidates a
     * composition, fans a frame to frame-clock awaiters, and recomposes.
     */
    public suspend fun runRecomposeAndApplyChanges() {
        while (!closed) {
            if (!hasPendingWork) {
                try {
                    workChannel.receive()
                } catch (e: Throwable) {
                    break // channel closed → stop the loop
                }
            }
            recompose()
        }
    }

    /** Stop the async loop and cancel all effect coroutines. */
    public fun close() {
        if (closed) return
        closed = true
        workChannel.close()
        effectJob.cancel()
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

    /** Let effects reach the recomposer's effect scope via the composer. */
    internal fun attachRecomposer(recomposer: Recomposer) {
        composer.recomposer = recomposer
    }

    override val isDisposed: Boolean
        get() = disposed

    override val hasInvalidations: Boolean
        get() = composer.hasInvalidations

    private fun ensureWriteObserver() {
        if (writeObserverHandle == null) {
            writeObserverHandle = StateObservation.registerWriteObserver { state ->
                if (composer.invalidate(state)) parent.notifyWorkAvailable()
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
        // SideEffects run after the composition they were queued in completes.
        composer.runSideEffects()
    }

    internal fun recompose() {
        if (disposed) return
        composer.beginRecomposePass()
        composeContent()
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        composer.disposeAll()
        content = null
        writeObserverHandle?.invoke()
        writeObserverHandle = null
        parent.unregisterComposition(this)
    }
}

/** Create a composition whose recomposition is driven by [parent]. */
public fun Composition(parent: Recomposer): Composition = KlioComposition(parent)
