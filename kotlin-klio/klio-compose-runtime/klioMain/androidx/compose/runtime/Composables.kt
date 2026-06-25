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
