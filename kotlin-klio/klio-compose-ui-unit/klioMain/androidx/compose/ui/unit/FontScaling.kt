// androidx.compose.ui.unit.FontScaling — klio's platform actual. Upstream
// declares `expect interface FontScaling` (its Sp<->Dp conversion is
// platform-defined) with a concrete `FontScalingLinear` for "most platforms
// except Android". klio is a desktop runtime, so the actual is the linear
// conversion, supplied here directly (the expect file is not vendored).
package androidx.compose.ui.unit

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.Stable
import androidx.compose.ui.unit.internal.JvmDefaultWithCompatibility

@Immutable
@JvmDefaultWithCompatibility
interface FontScaling {
    /** Current user preference for the scaling factor for fonts. */
    @Stable val fontScale: Float

    /** Convert [Dp] to Sp. Sp is used for font size, etc. */
    @Stable fun Dp.toSp(): TextUnit = (value / fontScale).sp

    /**
     * Convert Sp to [Dp].
     *
     * @throws IllegalStateException if a TextUnit other than SP is specified.
     */
    @Stable
    fun TextUnit.toDp(): Dp {
        check(type == TextUnitType.Sp) { "Only Sp can convert to Px" }
        return Dp(value * fontScale)
    }
}
