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
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
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

    /** The upstream frame clock effects await via withFrameNanos; the loop fans a
     * frame to its awaiters each pass. A new awaiter wakes the loop. */
    internal val frameClock: BroadcastFrameClock = BroadcastFrameClock { notifyWorkAvailable() }

    private var frameNanos: Long = 0L

    /** The scope effects (LaunchedEffect / rememberCoroutineScope / produceState)
     * launch onto. With a driver context (Recomposer(coroutineContext) under
     * runBlocking) it carries the driver's interceptor so launches dispatch +
     * suspend correctly. Without one (a plain Recomposer() used synchronously)
     * it pins Dispatchers.Unconfined so a finite effect still runs eagerly
     * instead of being abandoned on the worker pool when control returns. The
     * frame clock rides the context so withFrameNanos resolves it. */
    internal val effectScope: CoroutineScope =
        CoroutineScope(
            if (effectContext[ContinuationInterceptor] != null) effectContext + frameClock + effectJob
            else effectContext + frameClock + Dispatchers.Unconfined + effectJob,
        )

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

    /** True if any registered composition has pending invalidations, or a
     * frame-clock awaiter (a withFrameNanos effect) is waiting for a frame. */
    public val hasPendingWork: Boolean
        get() {
            if (frameClock.hasAwaiters) return true
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
            // Fan a frame to withFrameNanos awaiters (animations, produceState
            // pacing), then recompose any invalidated content.
            frameClock.sendFrame(frameNanos)
            frameNanos += 16_666_666L // ~60fps, monotonic + deterministic
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

internal class KlioComposition(
    private val parent: Recomposer,
    applier: Applier<*>? = null,
) : Composition {
    val composer: KlioComposer = KlioComposer()
    private val applier: Applier<*>? = applier
    private var content: (@Composable () -> Unit)? = null
    private var disposed: Boolean = false
    private var writeObserverHandle: (() -> Unit)? = null

    init {
        if (applier != null) {
            @Suppress("UNCHECKED_CAST")
            composer.applierNode = applier as Applier<Any?>
        }
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
        applier?.clear()
        content = null
        writeObserverHandle?.invoke()
        writeObserverHandle = null
        parent.unregisterComposition(this)
    }
}

/** Create a logic-only composition (no node emission) driven by [parent]. */
public fun Composition(parent: Recomposer): Composition = KlioComposition(parent)

/** Create a composition that emits into [applier]'s node tree, driven by [parent]. */
public fun Composition(applier: Applier<*>, parent: Recomposer): Composition =
    KlioComposition(parent, applier)
