// klio platform layer for kotlin.time.
//
// The kotlin.time commonMain sources (Duration, DurationUnit, Instant,
// Clock, TimeSource, ...) are consumed verbatim from the upstream
// Kotlin stdlib checkout (see klio-stdlib's pack_builder curated
// include list). Those files declare a handful of `internal expect`
// (and one `public expect enum`) members that every platform must
// supply an `actual` for. This file is klio's platform actual layer:
//
//  - DurationUnit            : the public `expect enum class`. Modelled
//                              on the Kotlin/JS actual (a `scale: Double`
//                              constructor parameter), which is pure
//                              Kotlin and numerically equivalent to the
//                              JVM `TimeUnit`-backed actual for every
//                              conversion the public API performs.
//  - convertDurationUnit     : pure scale arithmetic (Kotlin/JS form).
//  - convertDurationUnitOverflow
//  - formatToExactDecimals   : pure-Kotlin HALF_UP decimal formatting,
//                              matching java.text.DecimalFormat's
//                              RoundingMode.HALF_UP used by the JVM
//                              actual.
//  - durationAssertionsEnabled = false (assertions disabled, matching
//                              a JVM run without -ea, the parity target).
//  - ValueTimeMarkReading    = Long  (the Kotlin/JVM reading type).
//  - MonotonicTimeSource     : monotonic nanos, backed by the Rust host
//                              binding `__klio_time_monotonicNanos`.
//  - systemClockNow / serializedInstant : wall-clock millis from the
//                              Rust host binding `__klio_time_systemMillis`.
//
// The only genuinely platform-dependent readings (wall clock, monotonic
// clock) come from two tiny Rust host bindings registered in
// klio-stdlib; everything else is pure Kotlin so the consumed upstream
// arithmetic stays on the live execution path.

package kotlin.time

import kotlin.time.TimeSource.Monotonic.ValueTimeMark

// --- internal native helpers (bound natively by the klio host) ----

// Wall-clock time, milliseconds since the Unix epoch.
internal fun __klio_time_systemMillis(): Long = 0L

// A monotonically non-decreasing reading in nanoseconds. Only
// differences between readings are meaningful.
internal fun __klio_time_monotonicNanos(): Long = 0L

// --- DurationUnit (public expect enum class) ----------------------

@SinceKotlin("1.6")
public actual enum class DurationUnit(internal val scale: Double) {
    NANOSECONDS(1e0),
    MICROSECONDS(1e3),
    MILLISECONDS(1e6),
    SECONDS(1e9),
    MINUTES(60e9),
    HOURS(3600e9),
    DAYS(86400e9);
}

@SinceKotlin("1.3")
internal actual fun convertDurationUnit(value: Double, sourceUnit: DurationUnit, targetUnit: DurationUnit): Double {
    val sourceCompareTarget = sourceUnit.scale.compareTo(targetUnit.scale)
    return when {
        sourceCompareTarget > 0 -> value * (sourceUnit.scale / targetUnit.scale)
        sourceCompareTarget < 0 -> value / (targetUnit.scale / sourceUnit.scale)
        else -> value
    }
}

@SinceKotlin("1.5")
internal actual fun convertDurationUnitOverflow(value: Long, sourceUnit: DurationUnit, targetUnit: DurationUnit): Long {
    val sourceCompareTarget = sourceUnit.scale.compareTo(targetUnit.scale)
    return when {
        sourceCompareTarget > 0 -> value * (sourceUnit.scale / targetUnit.scale).toLong()
        sourceCompareTarget < 0 -> value / (targetUnit.scale / sourceUnit.scale).toLong()
        else -> value
    }
}

@SinceKotlin("1.5")
internal actual fun convertDurationUnit(value: Long, sourceUnit: DurationUnit, targetUnit: DurationUnit): Long {
    val sourceCompareTarget = sourceUnit.scale.compareTo(targetUnit.scale)
    return when {
        sourceCompareTarget > 0 -> {
            val scale = (sourceUnit.scale / targetUnit.scale).toLong()
            val result = value * scale
            when {
                result / scale == value -> result
                value > 0 -> Long.MAX_VALUE
                else -> Long.MIN_VALUE
            }
        }
        sourceCompareTarget < 0 -> value / (targetUnit.scale / sourceUnit.scale).toLong()
        else -> value
    }
}

// --- Duration.kt expects -----------------------------------------

// A JVM run without `-ea` has assertions disabled; the parity target
// is exactly that, so report disabled here.
internal actual val durationAssertionsEnabled: Boolean = false

// Pure-Kotlin HALF_UP fixed-decimal formatting, matching the JVM
// actual (java.text.DecimalFormat with RoundingMode.HALF_UP).
internal actual fun formatToExactDecimals(value: Double, decimals: Int): String {
    if (value.isNaN()) return "NaN"
    if (value.isInfinite()) return if (value < 0) "-Infinity" else "Infinity"

    val negative = value < 0.0 || (value == 0.0 && 1.0 / value < 0.0)
    val abs = if (negative) -value else value

    // Doubles at or above 2^63 are integral and exceed Long, so the
    // scale-and-split path below would saturate; expand the exact
    // binary value to decimal digits instead.
    if (abs >= 9.223372036854776E18) {
        val sb = StringBuilder()
        if (negative) sb.append('-')
        sb.append(exactIntegralDecimalString(abs))
        if (decimals > 0) {
            sb.append('.')
            var i = 0
            while (i < decimals) {
                sb.append('0')
                i += 1
            }
        }
        return sb.toString()
    }

    val pow = run {
        var p = 1.0
        var i = 0
        while (i < decimals) {
            p *= 10.0
            i += 1
        }
        p
    }

    // Scale, round half-up, and split into integer/fraction digits.
    val scaled = abs * pow
    val roundedScaled = kotlin.math.floor(scaled + 0.5)

    val intPart: Long
    val fracDigits: String
    if (decimals == 0) {
        intPart = roundedScaled.toLong()
        fracDigits = ""
    } else {
        val whole = kotlin.math.floor(roundedScaled / pow)
        intPart = whole.toLong()
        var frac = (roundedScaled - whole * pow).toLong()
        val sb = StringBuilder()
        // left-pad fractional part to `decimals` digits
        val raw = frac.toString()
        var pad = decimals - raw.length
        while (pad > 0) {
            sb.append('0')
            pad -= 1
        }
        sb.append(raw)
        fracDigits = sb.toString()
    }

    val sb = StringBuilder()
    if (negative && (intPart != 0L || fracDigits.any { it != '0' })) sb.append('-')
    sb.append(intPart.toString())
    if (decimals > 0) {
        sb.append('.')
        sb.append(fracDigits)
    }
    return sb.toString()
}

// Exact decimal digits of an integral Double >= 2^63: decompose into
// mantissa * 2^shift and double a little-endian digit array shift times.
private fun exactIntegralDecimalString(abs: Double): String {
    val bits = abs.toRawBits()
    val expField = ((bits ushr 52) and 0x7FFL).toInt()
    var mantissa = bits and 0xFFFFFFFFFFFFFL
    if (expField > 0) mantissa = mantissa or (1L shl 52)
    var shift = expField - 1075

    val digits = ArrayList<Int>()
    var m = mantissa
    while (m > 0L) {
        digits.add((m % 10L).toInt())
        m /= 10L
    }
    while (shift > 0) {
        var carry = 0
        var i = 0
        while (i < digits.size) {
            val v = digits[i] * 2 + carry
            digits[i] = v % 10
            carry = v / 10
            i += 1
        }
        if (carry > 0) digits.add(carry)
        shift -= 1
    }

    val sb = StringBuilder()
    var i = digits.size - 1
    while (i >= 0) {
        sb.append('0' + digits[i])
        i -= 1
    }
    return sb.toString()
}

// --- Instant.kt / Clock.kt expects -------------------------------

internal actual fun systemClockNow(): Instant =
    Instant.fromEpochMilliseconds(__klio_time_systemMillis())

internal actual fun serializedInstant(instant: Instant): Any =
    throw UnsupportedOperationException("Instant serialization is not supported on this platform")

// --- TimeSource.kt / TimeSources.kt expects ----------------------

// The reading wrapped by the inline `ValueTimeMark` value class; the
// Kotlin/JVM actual uses Long (nanoseconds), and so does klio.
@Suppress("ACTUAL_WITHOUT_EXPECT")
internal actual typealias ValueTimeMarkReading = Long

@SinceKotlin("1.3")
internal actual object MonotonicTimeSource : TimeSource.WithComparableMarks {
    private val zero: Long = __klio_time_monotonicNanos()
    private fun read(): Long = __klio_time_monotonicNanos() - zero
    override fun toString(): String = "TimeSource(monotonic)"

    actual override fun markNow(): ValueTimeMark = ValueTimeMark(read())

    actual fun elapsedFrom(timeMark: ValueTimeMark): Duration =
        saturatingDiff(read(), timeMark.reading, DurationUnit.NANOSECONDS)

    actual fun differenceBetween(one: ValueTimeMark, another: ValueTimeMark): Duration =
        saturatingOriginsDiff(one.reading, another.reading, DurationUnit.NANOSECONDS)

    actual fun adjustReading(timeMark: ValueTimeMark, duration: Duration): ValueTimeMark =
        ValueTimeMark(saturatingAdd(timeMark.reading, DurationUnit.NANOSECONDS, duration))
}
