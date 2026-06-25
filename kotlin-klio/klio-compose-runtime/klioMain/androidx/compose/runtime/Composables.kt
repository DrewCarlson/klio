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
        return computed
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
        return computed
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
        return computed
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
        return computed
    }
    @Suppress("UNCHECKED_CAST")
    return value as T
}

/**
 * Group [block] under a distinct positional identity per [keys]. Used to give a
 * stable identity to each item of a list so its `remember`/state survives
 * reordering. The interpreter already opens a group for this call; the explicit
 * keys disambiguate sibling invocations sharing one call site.
 */
@Composable
public fun <T> key(vararg keys: Any?, block: @Composable () -> T): T {
    val c = requireComposer()
    for (k in keys) c.changed(k)
    return block()
}
