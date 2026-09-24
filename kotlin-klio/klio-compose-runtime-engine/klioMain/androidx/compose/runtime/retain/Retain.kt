// The store surface of the `runtime-retain` module upstream, which the checkout
// does not carry: the ui Owner exposes a RetainedValuesStore and provides it
// through LocalRetainedValuesStore. Signatures follow runtime-retain's; the
// retain() composables themselves are not supplied.

package androidx.compose.runtime.retain

import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Keeps values that leave composition so content re-entering composition can
 * take them back instead of recreating them.
 */
public interface RetainedValuesStore {
    /** The value saved under [key] by content that exited composition, else [defaultValue]. */
    public fun consumeExitedValueOrDefault(key: Any, defaultValue: Any?): Any?

    /** Saves [value], retained by content exiting composition, under [key]. */
    public fun saveExitingValue(key: Any, value: Any?)

    /** The store's content entered composition. */
    public fun onContentEnteredComposition()

    /** The store's content is exiting composition. */
    public fun onContentExitComposition()
}

/** Callbacks for a retained value as it is retained, reused and retired. */
public interface RetainObserver {
    public fun onRetained()

    public fun onEnteredComposition()

    public fun onExitedComposition()

    public fun onRetired()

    public fun onUnused()
}

/** A store that keeps nothing: every exiting value is retired at once. */
public object ForgetfulRetainedValuesStore : RetainedValuesStore {
    override fun onContentEnteredComposition() {}

    override fun onContentExitComposition() {}

    override fun consumeExitedValueOrDefault(key: Any, defaultValue: Any?): Any? = defaultValue

    override fun saveExitingValue(key: Any, value: Any?) {
        if (value is RetainObserver) value.onRetired()
    }
}

/** The store retained values of the current composition go to. */
public val LocalRetainedValuesStore: ProvidableCompositionLocal<RetainedValuesStore> =
    staticCompositionLocalOf {
        ForgetfulRetainedValuesStore
    }
