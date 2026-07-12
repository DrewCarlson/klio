// klio's replacement for the compiler-intrinsic parts of Composables.kt.
//
// `currentComposer` is normally a compiler intrinsic that returns the synthetic
// `$composer` parameter; here it reads the interpreter's implicit-composer stack
// head. `remember` is normally lowered to `currentComposer.cache(...)`; here it
// calls the three slot primitives directly. The interpreter already brackets
// each `@Composable` call with the enclosing group, so `remember`'s slots land
// in the calling composable's group.

package androidx.compose.runtime

/** The active composer, or null outside a composition. */
internal fun currentComposerOrNull(): Composer? = __compose_currentComposer() as? Composer

internal fun requireComposer(): Composer =
    currentComposerOrNull()
        ?: error("currentComposer read with no active composition (call inside setContent)")

// A freshly remembered value implementing RememberObserver gets onRemembered now
// and onForgotten when the composition is disposed.
private fun <T> rememberObserved(c: Composer, computed: T): T {
    if (computed is RememberObserver) {
        computed.onRemembered()
        (c as KlioComposer).registerRememberObserver(computed)
    }
    return computed
}

/** The composer for the composition currently running, from the implicit stack. */
public val currentComposer: Composer
    get() = requireComposer()

/**
 * A stable hash identifying the enclosing composable's position in the
 * composition tree. `rememberSaveable` keys its stored value by this (via
 * `toString(radix)`) when the caller provides no explicit key. klio's
 * `CompositeKeyHashCode` is a `Long`, so the upstream `.toString(radix)` /
 * `.toLong()` operations are the stdlib `Long` ones.
 */
public val currentCompositeKeyHashCode: Long
    @Composable get() = requireComposer().compositeKeyHashCode

/** Remember a value across recompositions; [calculation] runs only on first composition. */
public fun <T> remember(calculation: () -> T): T {
    val c = requireComposer()
    val value = c.rememberedValue()
    if (value === Composer.Empty) {
        val computed = calculation()
        c.updateRememberedValue(computed)
        return rememberObserved(c, computed)
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/** Remember a value, recomputing whenever [key1] changes. */
public fun <T> remember(key1: Any?, calculation: () -> T): T {
    val c = requireComposer()
    val invalid = c.changed(key1)
    val value = c.rememberedValue()
    if (invalid || value === Composer.Empty) {
        val computed = calculation()
        c.updateRememberedValue(computed)
        return rememberObserved(c, computed)
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/** Remember a value, recomputing whenever [key1] or [key2] changes. */
public fun <T> remember(key1: Any?, key2: Any?, calculation: () -> T): T {
    val c = requireComposer()
    var invalid = c.changed(key1)
    invalid = c.changed(key2) || invalid
    val value = c.rememberedValue()
    if (invalid || value === Composer.Empty) {
        val computed = calculation()
        c.updateRememberedValue(computed)
        return rememberObserved(c, computed)
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/** Remember a value, recomputing whenever [key1], [key2] or [key3] changes. */
public fun <T> remember(key1: Any?, key2: Any?, key3: Any?, calculation: () -> T): T {
    val c = requireComposer()
    var invalid = c.changed(key1)
    invalid = c.changed(key2) || invalid
    invalid = c.changed(key3) || invalid
    val value = c.rememberedValue()
    if (invalid || value === Composer.Empty) {
        val computed = calculation()
        c.updateRememberedValue(computed)
        return rememberObserved(c, computed)
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/** Remember a value, recomputing whenever any of [keys] changes (upstream's vararg form). */
public fun <T> remember(vararg keys: Any?, calculation: () -> T): T {
    val c = requireComposer()
    var invalid = false
    for (k in keys) {
        invalid = c.changed(k) || invalid
    }
    val value = c.rememberedValue()
    if (invalid || value === Composer.Empty) {
        val computed = calculation()
        c.updateRememberedValue(computed)
        return rememberObserved(c, computed)
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/**
 * Remember a [MutableState] holding [newValue], updating it every composition.
 * Lets a long-lived lambda or effect read the latest value without restarting.
 */
public fun <T> rememberUpdatedState(newValue: T): State<T> {
    val state = remember { mutableStateOf(newValue) }
    state.value = newValue
    return state
}

/**
 * Give [block] a group identity derived from [keys] rather than its call site, so
 * its `remember`/state follows the key across reorders. Used per list item:
 * `for (item in items) key(item.id) { Row(item) }`. Implemented as a movable
 * group keyed by the joined keys (not the call-site span), so two iterations at
 * the same source position get distinct, reorder-stable groups.
 */
public fun <T> key(vararg keys: Any?, block: @Composable () -> T): T {
    val c = requireComposer()
    var h = -0x61c8864680b583ebL // golden-ratio seed, away from span-hash space
    for (k in keys) h = h * 31L + (if (k == null) 0L else k.hashCode().toLong())
    c.startGroup(h)
    try {
        return block()
    } finally {
        c.endGroup()
    }
}

/**
 * Recyclable content: on a [key] change the composition subtree is replaced.
 * klio rebuilds replaced nodes instead of recycling them, so this is [key]
 * with the reuse contract's name.
 */
public fun ReusableContent(key: Any?, content: @Composable () -> Unit) {
    key(key) { content() }
}

/**
 * Host for deactivatable content: while [active] is false the content
 * composes as deleted (klio drops its nodes and rebuilds on reactivation).
 */
public fun ReusableContentHost(active: Boolean, content: @Composable () -> Unit) {
    key(active) {
        if (active) content()
    }
}

/**
 * A [CompositionContext] for the current composition, remembered across
 * recompositions. A subcomposition created with `Composition(applier, context)`
 * is reparented to it, so it recomposes under the same recomposer as its parent —
 * the basis for `SubcomposeLayout` (lazy lists, constraint-driven content).
 */
public fun rememberCompositionContext(): CompositionContext {
    val c = requireComposer() as KlioComposer
    return remember { c.buildContext() }
}

// ----- node emission -----
//
// `ComposeNode` is the primitive every node-based Compose UI is built on: it
// emits a node of type T into the composition and diff-applies its properties.
// Upstream lowers `ComposeNode(factory, update) { content }` to these composer
// calls; klio's is the same shape against the synchronous `KlioComposer` (which
// reconciles the applier tree as the node groups open/close). The `E : Applier`
// type parameter is kept for source compatibility with consumers that name their
// applier; the runtime resolves the node against the composition's applier.

/**
 * Diff-applies a node's properties. Each `set`/`update` slot-memoizes its value,
 * so the property setter runs on first insert and only when the value changes.
 */
public class Updater<T>(@JvmField public val composer: Composer) {
    /** Set [value] via [block], running [block] on insert or when [value] changed. */
    public fun <V> set(value: V, block: T.(value: V) -> Unit) {
        val changed = composer.changed(value)
        if (composer.inserting || changed) {
            @Suppress("UNCHECKED_CAST")
            val node = composer.applier!!.current as T
            node.block(value)
        }
    }

    /** Like [set]; distinct name for updates to already-initialized nodes. */
    public fun <V> update(value: V, block: T.(value: V) -> Unit) {
        val changed = composer.changed(value)
        if (composer.inserting || changed) {
            @Suppress("UNCHECKED_CAST")
            val node = composer.applier!!.current as T
            node.block(value)
        }
    }

    /** Run [block] on the node only on the initial insert. */
    public fun init(block: T.() -> Unit) {
        if (composer.inserting) {
            @Suppress("UNCHECKED_CAST")
            val node = composer.applier!!.current as T
            node.block()
        }
    }

    /** Run [block] on the node every pass, unconditionally. */
    public fun reconcile(block: T.() -> Unit) {
        @Suppress("UNCHECKED_CAST")
        val node = composer.applier!!.current as T
        node.block()
    }
}

/** A skippable-content updater: applies node props inside a replaceable group. */
public class SkippableUpdater<T>(@JvmField public val composer: Composer) {
    public fun update(block: Updater<T>.() -> Unit) {
        composer.startReplaceableGroup(0x1e65194f)
        Updater<T>(composer).block()
        composer.endReplaceableGroup()
    }
}

/** Emit a node of type [T] with no child content. */
public fun <T, E : Applier<*>> ComposeNode(factory: () -> T, update: Updater<T>.() -> Unit) {
    val c = requireComposer()
    c.startNode()
    if (c.inserting) c.createNode(factory) else c.useNode()
    Updater<T>(c).update()
    c.endNode()
}

/** Emit a node of type [T]; nodes emitted in [content] become its children. */
public fun <T, E : Applier<*>> ComposeNode(
    factory: () -> T,
    update: Updater<T>.() -> Unit,
    content: @Composable () -> Unit,
) {
    val c = requireComposer()
    c.startNode()
    if (c.inserting) c.createNode(factory) else c.useNode()
    Updater<T>(c).update()
    content()
    c.endNode()
}

/** Emit a node of type [T] with a skippable prop updater and child [content]. */
public fun <T, E : Applier<*>> ComposeNode(
    factory: () -> T,
    update: Updater<T>.() -> Unit,
    skippableUpdate: SkippableUpdater<T>.() -> Unit,
    content: @Composable () -> Unit,
) {
    val c = requireComposer()
    c.startNode()
    if (c.inserting) c.createNode(factory) else c.useNode()
    Updater<T>(c).update()
    SkippableUpdater<T>(c).skippableUpdate()
    c.startReplaceableGroup(0x7ab4aae9)
    content()
    c.endReplaceableGroup()
    c.endNode()
}

/** Emit a reusable node of type [T] with no child content. */
public fun <T, E : Applier<*>> ReusableComposeNode(factory: () -> T, update: Updater<T>.() -> Unit) {
    val c = requireComposer()
    c.startReusableNode()
    if (c.inserting) c.createNode(factory) else c.useNode()
    Updater<T>(c).update()
    c.endNode()
}

/** Emit a reusable node of type [T]; nodes emitted in [content] become its children. */
public fun <T, E : Applier<*>> ReusableComposeNode(
    factory: () -> T,
    update: Updater<T>.() -> Unit,
    content: @Composable () -> Unit,
) {
    val c = requireComposer()
    c.startReusableNode()
    if (c.inserting) c.createNode(factory) else c.useNode()
    Updater<T>(c).update()
    content()
    c.endNode()
}
