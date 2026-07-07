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
    init {
        require(year in -999_999..999_999) { "Invalid year: $year" }
        require(monthNumber in 1..12) { "Invalid month: $monthNumber" }
        require(day in 1..daysInMonth(year, monthNumber)) { "Invalid day of month: $day" }
    }
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
    }
}

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
    init {
        require(hour in 0..23) { "Invalid hour: $hour" }
        require(minute in 0..59) { "Invalid minute: $minute" }
        require(second in 0..59) { "Invalid second: $second" }
        require(nanosecond in 0..999_999_999) { "Invalid nanosecond: $nanosecond" }
    }
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
    }
}

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
    }
}

// --- TimeZone ----------------------------------------------------
//
// klio-supplied (upstream's TimeZone.kt expect class pulls in
// UtcOffset / FixedOffsetTimeZone / the format DSL, out of scope).
// Conversion is chrono-backed in the host.

// `offsetSeconds` is non-null for a FIXED-OFFSET zone (`+03:00`, `UTC+3`, `Z`),
// whose instant<->local conversion is pure arithmetic and needs no IANA host
// binding; null for a named region zone (chrono-host-backed).
class TimeZone internal constructor(val id: String, internal val offsetSeconds: Int? = null) {
    override fun toString(): String = id
    override fun equals(other: Any?): Boolean = (other is TimeZone) && other.id == id
    override fun hashCode(): Int = id.hashCode()

    // Two-receiver conversions: usable as `with(zone) { ldt.toInstant() }`.
    fun Instant.toLocalDateTime(): LocalDateTime = this.toLocalDateTime(this@TimeZone)
    fun LocalDateTime.toInstant(): Instant = this.toInstant(this@TimeZone)

    companion object {
        val UTC: TimeZone = TimeZone("UTC")
        fun currentSystemDefault(): TimeZone = TimeZone(__kxdt_currentSystemTimeZoneId())
        fun of(zoneId: String): TimeZone {
            parseFixedOffsetSeconds(zoneId)?.let { off ->
                return TimeZone(if (off == 0) "Z" else UtcOffset(off).toString(), off)
            }
            if (!__kxdt_validateTimeZone(zoneId)) {
                throw IllegalTimeZoneException("Unknown time-zone id: $zoneId")
            }
            return TimeZone(zoneId)
        }
    }
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

// Upstream-named calendar arithmetic (Instant.kt is format/internal-heavy and
// not consumed, so these are supplied directly). The 2-arg shape is distinct
// from the `kotlin.time.Instant.plus(Duration)` member by arity.
fun Instant.plus(period: DateTimePeriod, timeZone: TimeZone): Instant = plusPeriod(period, timeZone)
fun Instant.minus(period: DateTimePeriod, timeZone: TimeZone): Instant = minusPeriod(period, timeZone)

// Unit-based arithmetic. A `TimeBased` unit is timezone-independent (a fixed
// nanosecond span); `DayBased` / `MonthBased` need the zone for calendar math.
// The nanosecond span is split into whole seconds + a nanos remainder so a
// large multiple (`plus(2^32, NANOSECOND)`) does not overflow.
fun Instant.plus(value: Long, unit: DateTimeUnit.TimeBased): Instant {
    val secondsPerUnit = unit.nanoseconds / 1_000_000_000L
    val nanosRem = unit.nanoseconds % 1_000_000_000L
    val addSeconds = value * secondsPerUnit + (value * nanosRem) / 1_000_000_000L
    val addNanos = (value * nanosRem) % 1_000_000_000L
    val r = __kxdt_addPeriod(epochSeconds, nanosecondsOfSecond, 0, 0, 0, 0, 0, addSeconds, addNanos, "UTC")
    return Instant.fromEpochSeconds(r[0], r[1])
}
fun Instant.plus(value: Int, unit: DateTimeUnit.TimeBased): Instant = plus(value.toLong(), unit)
fun Instant.minus(value: Long, unit: DateTimeUnit.TimeBased): Instant = plus(-value, unit)
fun Instant.minus(value: Int, unit: DateTimeUnit.TimeBased): Instant = plus(-value.toLong(), unit)

fun Instant.plus(value: Long, unit: DateTimeUnit, timeZone: TimeZone): Instant = when (unit) {
    is DateTimeUnit.TimeBased -> plus(value, unit)
    is DateTimeUnit.DayBased -> plusPeriod(DatePeriod(days = (value * unit.days).toInt()), timeZone)
    is DateTimeUnit.MonthBased -> plusPeriod(DatePeriod(months = (value * unit.months).toInt()), timeZone)
    else -> throw IllegalArgumentException("Unsupported DateTimeUnit: $unit")
}
fun Instant.plus(value: Int, unit: DateTimeUnit, timeZone: TimeZone): Instant = plus(value.toLong(), unit, timeZone)
fun Instant.minus(value: Long, unit: DateTimeUnit, timeZone: TimeZone): Instant = plus(-value, unit, timeZone)
fun Instant.minus(value: Int, unit: DateTimeUnit, timeZone: TimeZone): Instant = plus(-value.toLong(), unit, timeZone)

/** The offset from UTC, in whole seconds, at a specific moment in a time zone. */
class UtcOffset internal constructor(val totalSeconds: Int) {
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
    }
}

/** The wall-clock offset of [timeZone] from UTC at this instant. */
fun Instant.offsetIn(timeZone: TimeZone): UtcOffset {
    val ldt = toLocalDateTime(timeZone)
    val localSeconds = ldt.date.toEpochDays() * 86400L +
        ldt.hour.toLong() * 3600L + ldt.minute.toLong() * 60L + ldt.second.toLong()
    return UtcOffset((localSeconds - epochSeconds).toInt())
}

/** The calendar period between two instants in [timeZone] (largest units first). */
fun Instant.periodUntil(other: Instant, timeZone: TimeZone): DateTimePeriod {
    val thisLdt = toLocalDateTime(timeZone)
    val otherLdt = other.toLocalDateTime(timeZone)
    // Apply the date difference at this time-of-day; a day too far/short is
    // corrected below so the leftover is < 24h and lives in the time component.
    val timeAfterDate = LocalDateTime(otherLdt.date, thisLdt.time).toInstant(timeZone)
    val delta = when {
        other > this && timeAfterDate > other -> -1
        other < this && timeAfterDate < other -> 1
        else -> 0
    }
    val endDate = if (delta != 0) dateFromEpochDays(otherLdt.date.toEpochDays() + delta) else otherLdt.date
    val newInstant = LocalDateTime(endDate, thisLdt.time).toInstant(timeZone)
    val nanoseconds = (other.epochSeconds - newInstant.epochSeconds) * 1_000_000_000L +
        (other.nanosecondsOfSecond - newInstant.nanosecondsOfSecond).toLong()
    val datePeriod = thisLdt.date.periodUntil(endDate)
    return DateTimePeriod(
        months = datePeriod.totalMonths.toInt(),
        days = datePeriod.days,
        nanoseconds = nanoseconds,
    )
}

/** `other - this` as a calendar period in [timeZone]. */
fun Instant.minus(other: Instant, timeZone: TimeZone): DateTimePeriod = other.periodUntil(this, timeZone)
