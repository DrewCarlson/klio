// Coroutine-backed effects. klio runs launched coroutines eagerly to completion
// (there is no async frame-clock recomposer yet), so these are exact for finite
// effects — a block that fetches/derives and sets state, or launches work from a
// callback. A block that loops forever or relies on real suspension timing is a
// later (async-recomposer) phase. rememberCoroutineScope's scope and each
// LaunchedEffect's scope are cancelled when the composition is disposed (and a
// LaunchedEffect's previous scope is cancelled when its key changes).

package androidx.compose.runtime

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CancellationException
import kotlin.coroutines.CoroutineContext

// The scope effects launch onto: the recomposer's effect scope. Its context
// carries the driver's interceptor (when the recomposer was built with a driver
// context, e.g. Recomposer(coroutineContext) under runBlocking), so launches
// dispatch + suspend correctly; with a plain Recomposer() it falls back to the
// eager synchronous behavior.
private fun effectScopeOf(c: KlioComposer): CoroutineScope =
    c.recomposer?.effectScope ?: CoroutineScope(Job())

/** A CoroutineScope bound to the composition; cancelled when it is disposed. */
public fun rememberCoroutineScope(): CoroutineScope {
    val c = requireComposer() as KlioComposer
    val existing = c.rememberedValue()
    if (existing is CoroutineScope) return existing
    val scope = CoroutineScope(effectScopeOf(c).coroutineContext + Job())
    c.updateRememberedValue(scope)
    c.registerCleanup { scope.cancel() }
    return scope
}

private class LaunchedHolder {
    var job: Job? = null
}

private fun launchEffect(c: KlioComposer, changed: Boolean, block: suspend CoroutineScope.() -> Unit) {
    val slot = c.rememberedValue()
    if (slot is LaunchedHolder && !changed) return
    val holder: LaunchedHolder
    if (slot is LaunchedHolder) {
        holder = slot
        holder.job?.cancel()
    } else {
        holder = LaunchedHolder()
        c.updateRememberedValue(holder)
        c.registerCleanup { holder.job?.cancel() }
    }
    holder.job = effectScopeOf(c).launch { block() }
}

/** Launch [block] on first composition and whenever [key1] changes. */
public fun LaunchedEffect(key1: Any?, block: suspend CoroutineScope.() -> Unit) {
    val c = requireComposer() as KlioComposer
    val changed = c.changed(key1)
    launchEffect(c, changed, block)
}

/** Launch [block] on first composition and whenever [key1] or [key2] changes. */
public fun LaunchedEffect(key1: Any?, key2: Any?, block: suspend CoroutineScope.() -> Unit) {
    val c = requireComposer() as KlioComposer
    var changed = c.changed(key1)
    changed = c.changed(key2) || changed
    launchEffect(c, changed, block)
}

/** Launch [block] on first composition and whenever any of [keys] changes. */
public fun LaunchedEffect(vararg keys: Any?, block: suspend CoroutineScope.() -> Unit) {
    val c = requireComposer() as KlioComposer
    var changed = false
    for (k in keys) changed = c.changed(k) || changed
    launchEffect(c, changed, block)
}

// ----- produceState -----

public interface ProduceStateScope<T> : MutableState<T>, CoroutineScope {
    /** Suspend until the producer is disposed. (klio's eager model ends the
     * producer here rather than suspending forever; values set earlier stand.) */
    public suspend fun awaitDispose(onDispose: () -> Unit): Nothing
}

internal class ProduceStateScopeImpl<T>(
    private val state: MutableState<T>,
    private val scope: CoroutineScope,
) : ProduceStateScope<T> {
    override var value: T
        get() = state.value
        set(v) { state.value = v }
    override fun component1(): T = state.component1()
    override fun component2(): (T) -> Unit = state.component2()
    override val coroutineContext: CoroutineContext get() = scope.coroutineContext
    override suspend fun awaitDispose(onDispose: () -> Unit): Nothing {
        throw CancellationException("produceState awaitDispose")
    }
}

/** A [State] produced by a coroutine that sets `value`; relaunches on [key1] change. */
public fun <T> produceState(
    initialValue: T,
    key1: Any?,
    producer: suspend ProduceStateScope<T>.() -> Unit,
): State<T> {
    val c = requireComposer() as KlioComposer
    val result = remember { mutableStateOf(initialValue) }
    LaunchedEffect(key1) {
        val pss = ProduceStateScopeImpl(result, this)
        try {
            pss.producer()
        } catch (e: CancellationException) {
        }
    }
    return result
}

/** A [State] produced by a coroutine that sets `value`, launched once. */
public fun <T> produceState(
    initialValue: T,
    producer: suspend ProduceStateScope<T>.() -> Unit,
): State<T> = produceState(initialValue, Unit, producer)
