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
    override fun toString(): String =
        "${year.toString().padStart(4, '0')}-${monthNumber.toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}"

    override fun equals(other: Any?): Boolean {
        if (other !is LocalDate) return false
        return year == other.year && monthNumber == other.monthNumber && day == other.day
    }
    override fun hashCode(): Int = year * 10000 + monthNumber * 100 + day
}

internal fun isLeapYear(year: Int): Boolean =
    (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0)

internal fun daysInMonth(year: Int, month: Int): Int = when (month) {
    1, 3, 5, 7, 8, 10, 12 -> 31
    4, 6, 9, 11 -> 30
    else -> if (isLeapYear(year)) 29 else 28
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
}

// --- TimeZone ----------------------------------------------------
//
// klio-supplied (upstream's TimeZone.kt expect class pulls in
// UtcOffset / FixedOffsetTimeZone / the format DSL, out of scope).
// Conversion is chrono-backed in the host.

class TimeZone internal constructor(val id: String) {
    override fun toString(): String = id
    override fun equals(other: Any?): Boolean = (other is TimeZone) && other.id == id
    override fun hashCode(): Int = id.hashCode()

    companion object {
        fun currentSystemDefault(): TimeZone = TimeZone(__kxdt_currentSystemTimeZoneId())
        fun of(zoneId: String): TimeZone {
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

fun Instant.toLocalDateTime(timeZone: TimeZone): LocalDateTime {
    val parts = __kxdt_instantToLocalParts(epochSeconds, nanosecondsOfSecond, timeZone.id)
    return LocalDateTime(parts[0].toInt(), parts[1].toInt(), parts[2].toInt(),
        parts[3].toInt(), parts[4].toInt(), parts[5].toInt(), parts[6].toInt())
}

fun LocalDateTime.toInstant(timeZone: TimeZone): Instant {
    val r = __kxdt_localToInstant(year, monthNumber, dayOfMonth, hour, minute, second, nanosecond, timeZone.id)
    return Instant.fromEpochSeconds(r[0], r[1])
}

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
