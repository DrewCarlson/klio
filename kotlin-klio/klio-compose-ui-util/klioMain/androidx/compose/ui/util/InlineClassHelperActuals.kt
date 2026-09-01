// klio actuals for the androidx.compose.ui.util platform `expect`s the vendored
// geometry/unit inline value classes use: raw float/double bit reads and a fast
// round-to-int. klio's stdlib provides the underlying operations directly.

package androidx.compose.ui.util

import kotlin.math.roundToInt

actual fun floatFromBits(bits: Int): Float = Float.fromBits(bits)

actual fun doubleFromBits(bits: Long): Double = Double.fromBits(bits)

// Match Math.round semantics used by the upstream JVM/native actual:
// NaN rounds to 0 rather than throwing (roundToInt throws on NaN).
actual fun Float.fastRoundToInt(): Int = if (isNaN()) 0 else roundToInt()

actual fun Double.fastRoundToInt(): Int = if (isNaN()) 0 else roundToInt()
