// klio actuals for the androidx.compose.ui.util platform `expect`s the vendored
// geometry/unit inline value classes use: raw float/double bit reads and a fast
// round-to-int. klio's stdlib provides the underlying operations directly.

package androidx.compose.ui.util

import kotlin.math.roundToInt

actual fun floatFromBits(bits: Int): Float = Float.fromBits(bits)

actual fun doubleFromBits(bits: Long): Double = Double.fromBits(bits)

actual fun Float.fastRoundToInt(): Int = roundToInt()

actual fun Double.fastRoundToInt(): Int = roundToInt()
