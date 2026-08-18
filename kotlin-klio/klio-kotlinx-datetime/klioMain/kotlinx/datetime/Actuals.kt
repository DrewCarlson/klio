// klio platform layer for kotlinx-datetime.
//
// kotlinx-datetime 0.8.0 moved the moment-in-time type to the
// stdlib: `kotlinx.datetime.Instant` / `Clock` are deprecated
// typealiases to `kotlin.time.Instant` / `kotlin.time.Clock` (see
// the consumed DeprecatedInstant.kt / DeprecatedClock.kt). Now that
// klio runs real `kotlin.time`, the value types DateTimePeriod /
// DateTimeUnit and the Month / DayOfWeek enums are all consumed
// verbatim from the upstream submodule (see klio.toml `[[source]]`),
// and the internal math helpers have klio actuals
// (internal/MathActuals.kt).
//
// This file is the remaining klio-supplied platform layer: the
// LocalDate / LocalTime / LocalDateTime `actual class`es, the
// `TimeZone` value type, and the chrono-backed instant<->local
// conversion + calendar-period arithmetic over the Rust host
// bindings in this crate (src/lib.rs). The format-DSL parser
// combinators, the pure-Kotlin IANA tz database, and serialization
// remain intentionally out of scope.

package kotlinx.datetime

import kotlinx.datetime.internal.isLeapYear
import kotlinx.datetime.format.*
import kotlin.time.Instant

// --- internal native helpers (bound natively by the klio host) ----
//
// Each body below is unreachable when the kotlinx-datetime pack
// loads its Rust binding table at startup: the binding shadows the
// AST dispatch. If a caller still reaches the AST body (binding
// missing or removed), failing loudly with `NotImplementedError`
// is correct — silent zero / "UTC" returns hid binding-registration
// regressions in the past.

internal fun __kxdt_currentTimeMillis(): Long =
    throw NotImplementedError("__kxdt_currentTimeMillis: host binding not installed")

internal fun __kxdt_currentNanosOfSecond(): Int =
    throw NotImplementedError("__kxdt_currentNanosOfSecond: host binding not installed")

internal fun __kxdt_currentSystemTimeZoneId(): String =
    throw NotImplementedError("__kxdt_currentSystemTimeZoneId: host binding not installed")

// Returns [year, month, day, hour, minute, second, nanosecond].
internal fun __kxdt_instantToLocalParts(epochSeconds: Long, nanos: Int, tz: String): LongArray =
    throw NotImplementedError("__kxdt_instantToLocalParts: host binding not installed")

// Returns [epochSeconds, nanos].
internal fun __kxdt_localToInstant(
    year: Int, month: Int, day: Int,
    hour: Int, minute: Int, second: Int, nano: Int,
    tz: String,
): LongArray = throw NotImplementedError("__kxdt_localToInstant: host binding not installed")

internal fun __kxdt_availableZoneIds(): List<String> =
    throw NotImplementedError("__kxdt_availableZoneIds: host binding not installed")

internal fun __kxdt_validateTimeZone(id: String): Boolean =
    throw NotImplementedError("__kxdt_validateTimeZone: host binding not installed")

// Returns [epochSeconds, nanos] after applying the calendar period
// in the given tz.
internal fun __kxdt_addPeriod(
    epochSeconds: Long,
    nanos: Int,
    years: Int,
    months: Int,
    days: Int,
    hours: Int,
    minutes: Int,
    seconds: Int,
    nanoAdjust: Long,
    tz: String,
): LongArray = throw NotImplementedError("__kxdt_addPeriod: host binding not installed")

// --- LocalDate / LocalTime / LocalDateTime actuals ---------------

// `actual` for upstream `expect class LocalDate` (LocalDate.kt).
// format-DSL / LocalDateRange members are intentionally absent.
actual class LocalDate(
    val year: Int,
    val monthNumber: Int,
    val day: Int,
) : Comparable<LocalDate> {
    constructor(year: Int, month: Month, day: Int) : this(year, month.number, day)

    val month: Month get() = Month(monthNumber)
    val dayOfMonth: Int get() = day

    fun toEpochDays(): Long {
        val y = year.toLong()
        val m = monthNumber.toLong()
        var total = 365L * y
        if (y >= 0) {
            total += (y + 3) / 4 - (y + 99) / 100 + (y + 399) / 400
        } else {
            total -= y / -4 - y / -100 + y / -400
        }
        total += (367 * m - 362) / 12
        total += (day - 1).toLong()
        if (m > 2) {
            total -= 1
            if (!isLeapYear(year)) total -= 1
        }
        return total - 719528L
    }

    val dayOfWeek: DayOfWeek
        get() {
            val dow0 = ((toEpochDays() + 3) % 7 + 7) % 7
            return DayOfWeek((dow0 + 1).toInt())
        }

    val dayOfYear: Int
        get() {
            var d = day
            var mm = 1
            while (mm < monthNumber) {
                d += daysInMonth(year, mm)
                mm += 1
            }
            return d
        }

    override fun compareTo(other: LocalDate): Int {
        if (year != other.year) return year.compareTo(other.year)
        if (monthNumber != other.monthNumber) return monthNumber.compareTo(other.monthNumber)
        return day.compareTo(other.day)
    }
    override fun toString(): String {
        // A negative proleptic year formats as `-0001`, not `00-1`: pad the
        // magnitude, then re-attach the sign.
        val y = if (year < 0) "-" + (-year).toString().padStart(4, '0') else year.toString().padStart(4, '0')
        return "$y-${monthNumber.toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}"
    }

    override fun equals(other: Any?): Boolean {
        if (other !is LocalDate) return false
        return year == other.year && monthNumber == other.monthNumber && day == other.day
    }
    override fun hashCode(): Int = year * 10000 + monthNumber * 100 + day

    operator fun rangeTo(that: LocalDate): LocalDateRange = LocalDateRange.fromRangeTo(this, that)
    operator fun rangeUntil(that: LocalDate): LocalDateRange = LocalDateRange.fromRangeUntil(this, that)

    companion object {
        val MIN: LocalDate = LocalDate(-999_999, 1, 1)
        val MAX: LocalDate = LocalDate(999_999, 12, 31)

        fun orNull(year: Int, monthNumber: Int, day: Int): LocalDate? =
            if (year in -999_999..999_999 && monthNumber in 1..12 &&
                day in 1..monthNumber.monthLength(isLeapYear(year)))
                LocalDate(year, monthNumber, day) else null

        fun orNull(year: Int, month: Month, day: Int): LocalDate? = orNull(year, month.number, day)

        fun parseOrNull(input: CharSequence): LocalDate? = try { parse(input) } catch (e: Exception) { null }

        // ISO-8601 `yyyy-MM-dd` (with an optional leading `-` for a
        // negative proleptic year). The format-DSL overload's
        // `DateTimeFormat` parameter is intentionally unsupported; this
        // covers the common `LocalDate.parse("2024-06-15")` shape.
        fun parse(input: CharSequence): LocalDate {
            val s = input.toString()
            val neg = s.startsWith("-")
            val body = if (neg) s.substring(1) else s
            val parts = body.split("-")
            if (parts.size != 3) throw DateTimeFormatException("Invalid ISO-8601 date: $input")
            // ISO: 4-digit year (a signed year with more digits is only valid
            // via the leading `-`; a leading `+` or padded width is rejected),
            // 2-digit month and day, all digits.
            val yStr = parts[0]; val mStr = parts[1]; val dStr = parts[2]
            // An unsigned year is EXACTLY 4 digits (0000..9999); a wider year is
            // only valid with the leading `-` (this parser's supported sign),
            // where it is 4+ digits. `102017-10-01` (6 unsigned digits) is
            // rejected, matching kotlinx-datetime.
            val yearDigitsValid = if (neg) yStr.length >= 4 else yStr.length == 4
            if (!yearDigitsValid || mStr.length != 2 || dStr.length != 2 ||
                !yStr.all { it in '0'..'9' } || !mStr.all { it in '0'..'9' } || !dStr.all { it in '0'..'9' })
                throw DateTimeFormatException("Invalid ISO-8601 date: $input")
            val yMag = yStr.toIntOrNull() ?: throw DateTimeFormatException("Invalid ISO-8601 date: $input")
            val year = if (neg) -yMag else yMag
            val month = mStr.toInt(); val day = dStr.toInt()
            if (year !in -999_999..999_999 || month !in 1..12 || day !in 1..daysInMonth(year, month))
                throw DateTimeFormatException("Invalid ISO-8601 date: $input")
            return LocalDate(year, month, day)
        }

        fun fromEpochDays(epochDays: Long): LocalDate = dateFromEpochDays(epochDays)
        fun fromEpochDays(epochDays: Int): LocalDate = dateFromEpochDays(epochDays.toLong())

        fun parse(input: CharSequence, format: DateTimeFormat<LocalDate>): LocalDate = format.parse(input)

        fun Format(block: DateTimeFormatBuilder.WithDate.() -> Unit): DateTimeFormat<LocalDate> =
            LocalDateFormat.build(block)
    }

    object Formats {
        val ISO: DateTimeFormat<LocalDate> get() = ISO_DATE
        val ISO_BASIC: DateTimeFormat<LocalDate> get() = ISO_DATE_BASIC
    }
}

fun LocalDate.Companion.parseOrNull(input: CharSequence, format: DateTimeFormat<LocalDate>): LocalDate? =
    format.parseOrNull(input)

// `isLeapYear` is consumed from `kotlinx.datetime.internal` (imported above)
// rather than redeclared here, so a test importing both packages sees one
// declaration — matching upstream.
private fun daysInMonth(year: Int, month: Int): Int = when (month) {
    1, 3, 5, 7, 8, 10, 12 -> 31
    4, 6, 9, 11 -> 30
    else -> if (isLeapYear(year)) 29 else 28
}

// Inverse of LocalDate.toEpochDays: the proleptic-Gregorian date for a
// count of days since 1970-01-01 (Howard Hinnant's civil-from-days).
internal fun dateFromEpochDays(epochDays: Long): LocalDate {
    val z = epochDays + 719468L
    val era = (if (z >= 0) z else z - 146096) / 146097
    val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val y = yoe + era * 400
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val d = (doy - (153 * mp + 2) / 5 + 1).toInt()
    val m = (if (mp < 10) mp + 3 else mp - 9).toInt()
    val year = (if (m <= 2) y + 1L else y).toInt()
    return LocalDate(year, m, d)
}

// Add a (possibly negative) number of calendar months, clamping the day
// of month to the resulting month's length (2024-01-31 + 1 month =
// 2024-02-29).
internal fun localDatePlusMonths(date: LocalDate, monthsToAdd: Long): LocalDate {
    val total = date.year.toLong() * 12 + (date.monthNumber - 1) + monthsToAdd
    var y = total / 12
    var m0 = total % 12
    if (m0 < 0) {
        m0 += 12
        y -= 1
    }
    val newYear = y.toInt()
    val newMonth = (m0 + 1).toInt()
    val maxDay = daysInMonth(newYear, newMonth)
    val newDay = if (date.day > maxDay) maxDay else date.day
    return LocalDate(newYear, newMonth, newDay)
}

// Signed count of whole calendar months between two dates, day-aware
// (the partial trailing month is dropped, like java.time).
internal fun localDateMonthsBetween(start: LocalDate, end: LocalDate): Long {
    var months = (end.year.toLong() * 12 + (end.monthNumber - 1)) -
        (start.year.toLong() * 12 + (start.monthNumber - 1))
    if (months > 0 && end.day < start.day) {
        months -= 1
    } else if (months < 0 && end.day > start.day) {
        months += 1
    }
    return months
}

// `actual` implementations for the `expect` date-arithmetic operators
// and `until` helpers declared in upstream LocalDate.kt. Pure
// proleptic-Gregorian math over toEpochDays / dateFromEpochDays, so they
// need no host calls and stay timezone-independent.
actual operator fun LocalDate.plus(period: DatePeriod): LocalDate {
    val shifted = localDatePlusMonths(this, period.years.toLong() * 12 + period.months)
    return dateFromEpochDays(shifted.toEpochDays() + period.days)
}

actual fun LocalDate.plus(value: Long, unit: DateTimeUnit.DateBased): LocalDate = when (unit) {
    is DateTimeUnit.DayBased -> dateFromEpochDays(toEpochDays() + value * unit.days)
    is DateTimeUnit.MonthBased -> localDatePlusMonths(this, value * unit.months)
    else -> throw IllegalArgumentException("Unsupported DateTimeUnit: $unit")
}

actual fun LocalDate.plus(unit: DateTimeUnit.DateBased): LocalDate = plus(1L, unit)

actual fun LocalDate.daysUntil(other: LocalDate): Int =
    (other.toEpochDays() - toEpochDays()).toInt()

actual fun LocalDate.monthsUntil(other: LocalDate): Int =
    localDateMonthsBetween(this, other).toInt()

actual fun LocalDate.yearsUntil(other: LocalDate): Int =
    (localDateMonthsBetween(this, other) / 12).toInt()

actual fun LocalDate.until(other: LocalDate, unit: DateTimeUnit.DateBased): Long = when (unit) {
    is DateTimeUnit.DayBased -> (other.toEpochDays() - toEpochDays()) / unit.days
    is DateTimeUnit.MonthBased -> localDateMonthsBetween(this, other) / unit.months
    else -> throw IllegalArgumentException("Unsupported DateTimeUnit: $unit")
}

actual fun LocalDate.periodUntil(other: LocalDate): DatePeriod {
    val months = localDateMonthsBetween(this, other)
    val afterMonths = localDatePlusMonths(this, months)
    val days = (other.toEpochDays() - afterMonths.toEpochDays()).toInt()
    return DatePeriod((months / 12).toInt(), (months % 12).toInt(), days)
}

// `actual` for upstream `expect class LocalTime` (LocalTime.kt).
actual class LocalTime(
    val hour: Int,
    val minute: Int,
    val second: Int = 0,
    val nanosecond: Int = 0,
) : Comparable<LocalTime> {
    fun toSecondOfDay(): Int = (hour * 60 + minute) * 60 + second
    fun toMillisecondOfDay(): Int = toSecondOfDay() * 1_000 + nanosecond / 1_000_000
    fun toNanosecondOfDay(): Long =
        toSecondOfDay().toLong() * 1_000_000_000L + nanosecond.toLong()

    override operator fun compareTo(other: LocalTime): Int {
        if (hour != other.hour) return hour.compareTo(other.hour)
        if (minute != other.minute) return minute.compareTo(other.minute)
        if (second != other.second) return second.compareTo(other.second)
        return nanosecond.compareTo(other.nanosecond)
    }
    override fun toString(): String {
        val h = hour.toString().padStart(2, '0')
        val m = minute.toString().padStart(2, '0')
        val s = second.toString().padStart(2, '0')
        return if (nanosecond == 0) "$h:$m:$s" else "$h:$m:$s.${nanosecond.toString().padStart(9, '0')}"
    }
    override fun equals(other: Any?): Boolean {
        if (other !is LocalTime) return false
        return hour == other.hour && minute == other.minute && second == other.second && nanosecond == other.nanosecond
    }
    override fun hashCode(): Int = (((hour * 60 + minute) * 60 + second) * 1_000_000_000) + nanosecond

    companion object {
        val MIN: LocalTime = LocalTime(0, 0, 0, 0)
        val MAX: LocalTime = LocalTime(23, 59, 59, 999_999_999)

        fun fromSecondOfDay(secondOfDay: Int): LocalTime {
            if (secondOfDay < 0 || secondOfDay > 86_399)
                throw IllegalArgumentException("Invalid value: secondOfDay=$secondOfDay")
            return LocalTime(secondOfDay / 3600, (secondOfDay % 3600) / 60, secondOfDay % 60, 0)
        }

        fun fromMillisecondOfDay(millisecondOfDay: Int): LocalTime {
            if (millisecondOfDay < 0 || millisecondOfDay > 86_399_999)
                throw IllegalArgumentException("Invalid value: millisecondOfDay=$millisecondOfDay")
            val sec = millisecondOfDay / 1_000
            return LocalTime(sec / 3600, (sec % 3600) / 60, sec % 60, (millisecondOfDay % 1_000) * 1_000_000)
        }

        fun fromNanosecondOfDay(nanosecondOfDay: Long): LocalTime {
            if (nanosecondOfDay < 0 || nanosecondOfDay > 86_399_999_999_999L)
                throw IllegalArgumentException("Invalid value: nanosecondOfDay=$nanosecondOfDay")
            val sec = (nanosecondOfDay / 1_000_000_000L).toInt()
            return LocalTime(sec / 3600, (sec % 3600) / 60, sec % 60, (nanosecondOfDay % 1_000_000_000L).toInt())
        }

        fun orNull(hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0): LocalTime? =
            if (hour in 0..23 && minute in 0..59 && second in 0..59 && nanosecond in 0..999_999_999)
                LocalTime(hour, minute, second, nanosecond) else null

        fun parseOrNull(input: CharSequence): LocalTime? = try { parse(input) } catch (e: Exception) { null }

        // ISO-8601 `HH:mm[:ss[.fff…]]`.
        fun parse(input: CharSequence): LocalTime {
            val parts = input.toString().split(":")
            if (parts.size < 2 || parts.size > 3) throw DateTimeFormatException("Invalid ISO-8601 time: $input")
            fun digits2(x: String): Int {
                if (x.length != 2 || !x.all { it in '0'..'9' }) throw DateTimeFormatException("Invalid ISO-8601 time: $input")
                return x.toInt()
            }
            val hour = digits2(parts[0])
            val minute = digits2(parts[1])
            var second = 0
            var nanos = 0
            if (parts.size == 3) {
                val sec = parts[2]
                val dot = sec.indexOf('.')
                if (dot >= 0) {
                    second = digits2(sec.substring(0, dot))
                    val frac = sec.substring(dot + 1)
                    if (frac.isEmpty() || frac.length > 9 || !frac.all { it in '0'..'9' })
                        throw DateTimeFormatException("Invalid ISO-8601 time: $input")
                    nanos = frac.padEnd(9, '0').toInt()
                } else {
                    second = digits2(sec)
                }
            }
            if (hour !in 0..23 || minute !in 0..59 || second !in 0..59)
                throw DateTimeFormatException("Invalid ISO-8601 time: $input")
            return LocalTime(hour, minute, second, nanos)
        }

        fun parse(input: CharSequence, format: DateTimeFormat<LocalTime>): LocalTime = format.parse(input)

        fun Format(builder: DateTimeFormatBuilder.WithTime.() -> Unit): DateTimeFormat<LocalTime> =
            LocalTimeFormat.build(builder)
    }

    object Formats {
        val ISO: DateTimeFormat<LocalTime> get() = ISO_TIME
    }
}

fun LocalTime.Companion.parseOrNull(input: CharSequence, format: DateTimeFormat<LocalTime>): LocalTime? =
    format.parseOrNull(input)

// `actual` for upstream `expect class LocalDateTime` (LocalDateTime.kt).
actual class LocalDateTime(
    val date: LocalDate,
    val time: LocalTime,
) : Comparable<LocalDateTime> {
    constructor(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0)
        : this(LocalDate(year, month, day), LocalTime(hour, minute, second, nanosecond))
    constructor(year: Int, month: Month, day: Int, hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0)
        : this(LocalDate(year, month.number, day), LocalTime(hour, minute, second, nanosecond))

    val year: Int get() = date.year
    val monthNumber: Int get() = date.monthNumber
    val month: Month get() = date.month
    val day: Int get() = date.day
    val dayOfMonth: Int get() = date.day
    val dayOfWeek: DayOfWeek get() = date.dayOfWeek
    val dayOfYear: Int get() = date.dayOfYear
    val hour: Int get() = time.hour
    val minute: Int get() = time.minute
    val second: Int get() = time.second
    val nanosecond: Int get() = time.nanosecond

    override fun compareTo(other: LocalDateTime): Int {
        val d = date.compareTo(other.date)
        if (d != 0) return d
        return time.compareTo(other.time)
    }
    override fun toString(): String = "${date}T${time}"
    override fun equals(other: Any?): Boolean {
        if (other !is LocalDateTime) return false
        return date == other.date && time == other.time
    }
    override fun hashCode(): Int = date.hashCode() * 31 + time.hashCode()

    companion object {
        val MIN: LocalDateTime = LocalDateTime(LocalDate.MIN, LocalTime.MIN)
        val MAX: LocalDateTime = LocalDateTime(LocalDate.MAX, LocalTime.MAX)

        fun parseOrNull(input: CharSequence): LocalDateTime? = try { parse(input) } catch (e: Exception) { null }

        fun orNull(year: Int, monthNumber: Int, day: Int, hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0): LocalDateTime? {
            val d = LocalDate.orNull(year, monthNumber, day) ?: return null
            val t = LocalTime.orNull(hour, minute, second, nanosecond) ?: return null
            return LocalDateTime(d, t)
        }

        fun orNull(year: Int, month: Month, day: Int, hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0): LocalDateTime? =
            orNull(year, month.number, day, hour, minute, second, nanosecond)

        // ISO-8601 `<date>T<time>`.
        fun parse(input: CharSequence): LocalDateTime {
            val s = input.toString()
            val t = s.indexOf('T')
            if (t < 0) throw DateTimeFormatException("Invalid ISO-8601 date-time: $input")
            return LocalDateTime(LocalDate.parse(s.substring(0, t)), LocalTime.parse(s.substring(t + 1)))
        }

        fun parse(input: CharSequence, format: DateTimeFormat<LocalDateTime>): LocalDateTime = format.parse(input)

        fun Format(builder: DateTimeFormatBuilder.WithDateTime.() -> Unit): DateTimeFormat<LocalDateTime> =
            LocalDateTimeFormat.build(builder)
    }

    object Formats {
        val ISO: DateTimeFormat<LocalDateTime> get() = ISO_DATETIME
    }
}

fun LocalDateTime.Companion.parseOrNull(input: CharSequence, format: DateTimeFormat<LocalDateTime>): LocalDateTime? =
    format.parseOrNull(input)

// --- TimeZone ----------------------------------------------------
//
// klio-supplied (upstream's TimeZone.kt expect class pulls in
// UtcOffset / FixedOffsetTimeZone / the format DSL, out of scope).
// Conversion is chrono-backed in the host.

// `offsetSeconds` is non-null for a FIXED-OFFSET zone (`+03:00`, `UTC+3`, `Z`),
// whose instant<->local conversion is pure arithmetic and needs no IANA host
// binding; null for a named region zone (chrono-host-backed).
open class TimeZone internal constructor(val id: String, internal val offsetSeconds: Int? = null) {
    override fun toString(): String = id
    override fun equals(other: Any?): Boolean = (other is TimeZone) && other.id == id
    override fun hashCode(): Int = id.hashCode()

    // Two-receiver conversions: usable as `with(zone) { ldt.toInstant() }`.
    fun Instant.toLocalDateTime(): LocalDateTime = this.toLocalDateTime(this@TimeZone)
    fun LocalDateTime.toInstant(): Instant = this.toInstant(this@TimeZone)

    companion object {
        val UTC: FixedOffsetTimeZone = FixedOffsetTimeZone(UtcOffset.ZERO, "UTC")
        fun currentSystemDefault(): TimeZone = TimeZone(__kxdt_currentSystemTimeZoneId())
        fun of(zoneId: String): TimeZone {
            parseFixedOffsetSeconds(zoneId)?.let { off ->
                if (zoneId == "UTC" || zoneId == "GMT" || zoneId == "UT") return FixedOffsetTimeZone(UtcOffset(off), zoneId)
                return FixedOffsetTimeZone(UtcOffset(off))
            }
            if (!__kxdt_validateTimeZone(zoneId)) {
                throw IllegalTimeZoneException("Unknown time-zone id: $zoneId")
            }
            return TimeZone(zoneId)
        }

        val availableZoneIds: Set<String> get() = __kxdt_availableZoneIds().toSet()
    }
}

/// A zone whose offset from UTC is constant. `id` is the offset's ISO
/// rendering (`Z`, `+03:00`) unless the zone was named (`UTC`, `GMT`).
class FixedOffsetTimeZone internal constructor(val offset: UtcOffset, id: String) :
    TimeZone(id, offset.totalSeconds) {
    constructor(offset: UtcOffset) : this(offset, offset.toString())

    val totalSeconds: Int get() = offset.totalSeconds
}

/** The offset from UTC this zone applies at [instant]. */
fun TimeZone.offsetAt(instant: Instant): UtcOffset {
    offsetSeconds?.let { return UtcOffset(it) }
    val local = instant.toLocalDateTime(this)
    val localSec = local.date.toEpochDays() * 86400L +
        local.hour.toLong() * 3600L + local.minute.toLong() * 60L + local.second.toLong()
    return UtcOffset((localSec - instant.epochSeconds).toInt())
}

/** The zone's own conversion, named as upstream's `TimeZone` member is. */
fun TimeZone.localDateTimeToInstant(dateTime: LocalDateTime): Instant = dateTime.toInstant(this)

internal fun localDateTimeToInstant(
    dateTime: LocalDateTime,
    timeZone: TimeZone,
    preferred: UtcOffset? = null,
): Instant {
    if (preferred != null && timeZone.offsetSeconds == null) {
        // A wall-clock time that still exists under the preferred offset keeps
        // it (upstream's gap/overlap resolution), otherwise the zone decides.
        val candidate = dateTime.toInstant(preferred)
        if (candidate.toLocalDateTime(timeZone) == dateTime) return candidate
    }
    return dateTime.toInstant(timeZone)
}

// --- instant <-> local conversion (over kotlin.time.Instant) -----
//
// Upstream declares these as `expect fun Instant.toLocalDateTime(tz)`
// in TimeZone.kt (not consumed); klio supplies them directly over
// the chrono host binding.

// Parse a fixed-offset zone id (`Z`, `UTC`, `GMT`, `+3`, `-06:30`, `UTC+3`,
// `+03:00:00`) to total seconds, or null when it is a named region zone.
internal fun parseFixedOffsetSeconds(id: String): Int? {
    if (id == "Z" || id == "z" || id == "UTC" || id == "GMT" || id == "UT") return 0
    var s = id
    for (prefix in listOf("UTC", "GMT", "UT")) {
        if (s.startsWith(prefix)) { s = s.substring(prefix.length); break }
    }
    if (s.isEmpty()) return null
    val sign = when (s[0]) { '+' -> 1; '-' -> -1; else -> return null }
    val body = s.substring(1)
    if (body.isEmpty()) return null
    val parts = body.split(":")
    if (parts.size > 3) return null
    val h = parts[0].toIntOrNull() ?: return null
    val m = if (parts.size > 1) (parts[1].toIntOrNull() ?: return null) else 0
    val sec = if (parts.size > 2) (parts[2].toIntOrNull() ?: return null) else 0
    if (m !in 0..59 || sec !in 0..59) return null
    return sign * (h * 3600 + m * 60 + sec)
}

// Split epoch seconds into (floor days, seconds-of-day) with a non-negative
// remainder, for a fixed-offset local calendar.
private fun epochSecondsToLocalDateTime(sec: Long, nanos: Int): LocalDateTime {
    val days = if (sec >= 0) sec / 86400L else -((-sec + 86399L) / 86400L)
    val secOfDay = sec - days * 86400L
    return LocalDateTime(
        dateFromEpochDays(days),
        LocalTime((secOfDay / 3600L).toInt(), ((secOfDay % 3600L) / 60L).toInt(), (secOfDay % 60L).toInt(), nanos),
    )
}

fun Instant.toLocalDateTime(timeZone: TimeZone): LocalDateTime {
    timeZone.offsetSeconds?.let { off ->
        return epochSecondsToLocalDateTime(epochSeconds + off, nanosecondsOfSecond)
    }
    val parts = __kxdt_instantToLocalParts(epochSeconds, nanosecondsOfSecond, timeZone.id)
    return LocalDateTime(parts[0].toInt(), parts[1].toInt(), parts[2].toInt(),
        parts[3].toInt(), parts[4].toInt(), parts[5].toInt(), parts[6].toInt())
}

fun LocalDateTime.toInstant(timeZone: TimeZone): Instant {
    timeZone.offsetSeconds?.let { off ->
        val localSec = date.toEpochDays() * 86400L + hour.toLong() * 3600L + minute.toLong() * 60L + second.toLong()
        return Instant.fromEpochSeconds(localSec - off, nanosecond.toLong())
    }
    val r = __kxdt_localToInstant(year, monthNumber, dayOfMonth, hour, minute, second, nanosecond, timeZone.id)
    return Instant.fromEpochSeconds(r[0], r[1])
}

fun Instant.toLocalDateTime(offset: UtcOffset): LocalDateTime =
    epochSecondsToLocalDateTime(epochSeconds + offset.totalSeconds, nanosecondsOfSecond)

fun LocalDateTime.toInstant(offset: UtcOffset): Instant {
    val localSec = date.toEpochDays() * 86400L + hour.toLong() * 3600L +
        minute.toLong() * 60L + second.toLong()
    return Instant.fromEpochSeconds(localSec - offset.totalSeconds, nanosecond.toLong())
}

/** The instant at the start of this day (midnight) in [timeZone]. */
fun LocalDate.atStartOfDayIn(timeZone: TimeZone): Instant =
    LocalDateTime(this, LocalTime(0, 0, 0, 0)).toInstant(timeZone)

// Calendar-aware period add. klio's overload resolver picks
// `Instant.plus(Duration)` (kotlin.time member) vs this by signature
// now, but the upstream `Instant.plus(DateTimePeriod, TimeZone)`
// lives in Instant.kt (format/internal heavy, not consumed), so the
// klio surface keeps the explicit name used by the test corpus.
fun Instant.plusPeriod(period: DateTimePeriod, timeZone: TimeZone): Instant {
    val r = __kxdt_addPeriod(
        epochSeconds, nanosecondsOfSecond,
        period.years, period.months, period.days,
        period.hours, period.minutes, period.seconds, period.nanoseconds.toLong(),
        timeZone.id,
    )
    return Instant.fromEpochSeconds(r[0], r[1])
}

fun Instant.minusPeriod(period: DateTimePeriod, timeZone: TimeZone): Instant = plusPeriod(
    DateTimePeriod(
        years = -period.years, months = -period.months, days = -period.days,
        hours = -period.hours, minutes = -period.minutes, seconds = -period.seconds,
        nanoseconds = -period.nanoseconds.toLong(),
    ),
    timeZone,
)

// Calendar arithmetic on Instant (plus/minus by period or unit, periodUntil,
// until, daysUntil/monthsUntil/yearsUntil) comes from upstream Instant.kt.

/** The offset from UTC, in whole seconds, at a specific moment in a time zone. */
class UtcOffset internal constructor(val totalSeconds: Int) {
    // Component factory: `UtcOffset(hours = 3)`, `UtcOffset(seconds = -30)`. A
    // single positional Int still binds the internal `totalSeconds` primary.
    constructor(hours: Int? = null, minutes: Int? = null, seconds: Int? = null) :
        this(utcOffsetTotalSeconds(hours, minutes, seconds))

    override fun toString(): String {
        if (totalSeconds == 0) return "Z"
        val sign = if (totalSeconds < 0) "-" else "+"
        val abs = if (totalSeconds < 0) -totalSeconds else totalSeconds
        val hh = (abs / 3600).toString().padStart(2, '0')
        val mm = ((abs % 3600) / 60).toString().padStart(2, '0')
        val s = abs % 60
        return if (s == 0) "$sign$hh:$mm" else "$sign$hh:$mm:${s.toString().padStart(2, '0')}"
    }
    override fun equals(other: Any?): Boolean = other is UtcOffset && other.totalSeconds == totalSeconds
    override fun hashCode(): Int = totalSeconds

    companion object {
        val ZERO: UtcOffset = UtcOffset(0)

        fun parse(input: CharSequence): UtcOffset {
            val s = input.toString()
            if (s == "Z" || s == "z") return ZERO
            val secs = parseFixedOffsetSeconds(s)
                ?: throw DateTimeFormatException("Invalid ISO-8601 UTC offset: $input")
            if (secs < -18 * 3600 || secs > 18 * 3600)
                throw DateTimeFormatException("UTC offset out of range: $input")
            return UtcOffset(secs)
        }
        fun parseOrNull(input: CharSequence): UtcOffset? = try { parse(input) } catch (e: Exception) { null }
        fun orNull(hours: Int? = null, minutes: Int? = null, seconds: Int? = null): UtcOffset? =
            try { UtcOffset(hours, minutes, seconds) } catch (e: Exception) { null }

        fun parse(input: CharSequence, format: DateTimeFormat<UtcOffset>): UtcOffset = format.parse(input)

        fun Format(block: DateTimeFormatBuilder.WithUtcOffset.() -> Unit): DateTimeFormat<UtcOffset> =
            UtcOffsetFormat.build(block)
    }

    object Formats {
        val ISO: DateTimeFormat<UtcOffset> get() = ISO_OFFSET
        val ISO_BASIC: DateTimeFormat<UtcOffset> get() = ISO_OFFSET_BASIC
        val FOUR_DIGITS: DateTimeFormat<UtcOffset> get() = FOUR_DIGIT_OFFSET
    }
}

fun UtcOffset.Companion.parseOrNull(input: CharSequence, format: DateTimeFormat<UtcOffset>): UtcOffset? =
    format.parseOrNull(input)

fun UtcOffset.format(format: DateTimeFormat<UtcOffset>): String = format.format(this)

private fun utcOffsetTotalSeconds(hours: Int?, minutes: Int?, seconds: Int?): Int = when {
    hours != null -> utcOffsetHms(hours, minutes ?: 0, seconds ?: 0)
    minutes != null -> utcOffsetHms(minutes / 60, minutes % 60, seconds ?: 0)
    else -> utcOffsetCheckTotal(seconds ?: 0)
}

private fun utcOffsetCheckTotal(total: Int): Int {
    if (total < -18 * 3600 || total > 18 * 3600)
        throw IllegalArgumentException("Total seconds value is out of range: $total")
    return total
}

private fun utcOffsetHms(hours: Int, minutes: Int, seconds: Int): Int {
    if (hours < -18 || hours > 18)
        throw IllegalArgumentException("Zone offset hours not in valid range: value $hours is not in the range -18 to 18")
    if (hours > 0) {
        if (minutes < 0 || seconds < 0)
            throw IllegalArgumentException("Zone offset minutes and seconds must be positive because hours is positive")
    } else if (hours < 0) {
        if (minutes > 0 || seconds > 0)
            throw IllegalArgumentException("Zone offset minutes and seconds must be negative because hours is negative")
    } else if (minutes > 0 && seconds < 0 || minutes < 0 && seconds > 0) {
        throw IllegalArgumentException("Zone offset minutes and seconds must have the same sign")
    }
    val am = if (minutes < 0) -minutes else minutes
    val asec = if (seconds < 0) -seconds else seconds
    if (am > 59)
        throw IllegalArgumentException("Zone offset minutes not in valid range: value $am is not in the range 0 to 59")
    if (asec > 59)
        throw IllegalArgumentException("Zone offset seconds not in valid range: value $asec is not in the range 0 to 59")
    return utcOffsetCheckTotal(hours * 3600 + minutes * 60 + seconds)
}

/** The fixed-offset time zone with this offset. */
fun UtcOffset.asTimeZone(): FixedOffsetTimeZone = FixedOffsetTimeZone(this)

/** The wall-clock offset of [timeZone] from UTC at this instant. */
fun Instant.offsetIn(timeZone: TimeZone): UtcOffset {
    val ldt = toLocalDateTime(timeZone)
    val localSeconds = ldt.date.toEpochDays() * 86400L +
        ldt.hour.toLong() * 3600L + ldt.minute.toLong() * 60L + ldt.second.toLong()
    return UtcOffset((localSeconds - epochSeconds).toInt())
}

