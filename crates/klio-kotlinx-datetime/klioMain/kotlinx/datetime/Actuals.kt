// klio platform layer for kotlinx-datetime.
//
// Upstream kotlinx-datetime 0.8.0 core commonMain declares every
// value type (LocalDate/Time/DateTime, TimeZone, Clock,
// DateTimePeriod, DateTimeUnit, plus the `kotlin.time.Instant`
// extensions) only as `expect` / extensions over machinery klio
// does not have (kotlinx-serialization runtime, the
// kotlinx.datetime.format parser-combinator DSL, the internal IANA
// tz database + Tzfile reader, stdlib `kotlin.time.Instant`). The
// only commonMain files klio consumes verbatim are the self-
// contained `Month` / `DayOfWeek` enums + factories and the public
// exception types (see klio.toml `[[source]]`).
//
// This file is the klio-supplied platform layer: the concrete value
// types and operators the consumer needs, implemented in thin Kotlin
// over the Rust host bindings in this crate (src/lib.rs) — system
// clock, chrono-backed Instant<->LocalDateTime conversion, ISO
// parse/format, calendar arithmetic. `Month` / `DayOfWeek` are NOT
// declared here; `LocalDate.month` / `LocalDateTime.month` resolve to
// the real upstream `Month` enum via upstream's own `Month(number)`
// factory, so the consumed upstream code is on the live path.
//
// Limitation: TimeZone is backed by chrono-tz in the host (real IANA
// rules for conversion), but the pure-Kotlin tz database, the format
// DSL, and serialization are intentionally absent. Anything depending
// on those is out of scope for this pack.

package kotlinx.datetime

// --- internal native helpers (bound natively by the klio host) ----

internal fun __kxdt_currentTimeMillis(): Long = 0L
internal fun __kxdt_currentNanosOfSecond(): Int = 0
internal fun __kxdt_currentSystemTimeZoneId(): String = "UTC"

// Returns [year, month, day, hour, minute, second, nanosecond].
internal fun __kxdt_instantToLocalParts(epochSeconds: Long, nanos: Int, tz: String): LongArray =
    longArrayOf(1970L, 1L, 1L, 0L, 0L, 0L, 0L)

// Returns [epochSeconds, nanos].
internal fun __kxdt_localToInstant(
    year: Int, month: Int, day: Int,
    hour: Int, minute: Int, second: Int, nano: Int,
    tz: String,
): LongArray = longArrayOf(0L, 0L)

internal fun __kxdt_instantToString(epochSeconds: Long, nanos: Int): String = ""
internal fun __kxdt_parseInstant(s: String): LongArray = longArrayOf(0L, 0L)
internal fun __kxdt_validateTimeZone(id: String): Boolean = true

// --- public API ---

class Instant internal constructor(
    val epochSeconds: Long,
    val nanosecondsOfSecond: Int,
) : Comparable<Instant> {
    fun toEpochMilliseconds(): Long =
        epochSeconds * 1000L + (nanosecondsOfSecond / 1_000_000).toLong()

    operator fun plus(duration: Duration): Instant {
        val addedSec = duration.inWholeSeconds
        val addedNano = duration.nanosPart
        var s = epochSeconds + addedSec
        var n = nanosecondsOfSecond + addedNano
        if (n >= 1_000_000_000) { s += 1; n -= 1_000_000_000 }
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Instant(s, n)
    }

    operator fun minus(duration: Duration): Instant = plus(Duration(-duration.inWholeSeconds, -duration.nanosPart))

    operator fun minus(other: Instant): Duration {
        var s = epochSeconds - other.epochSeconds
        var n = nanosecondsOfSecond - other.nanosecondsOfSecond
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Duration(s, n)
    }

    override fun compareTo(other: Instant): Int {
        if (epochSeconds != other.epochSeconds) return if (epochSeconds < other.epochSeconds) -1 else 1
        return nanosecondsOfSecond.compareTo(other.nanosecondsOfSecond)
    }

    override fun toString(): String = __kxdt_instantToString(epochSeconds, nanosecondsOfSecond)

    override fun equals(other: Any?): Boolean {
        if (other !is Instant) return false
        return epochSeconds == other.epochSeconds && nanosecondsOfSecond == other.nanosecondsOfSecond
    }

    override fun hashCode(): Int = (epochSeconds.hashCode() * 31) + nanosecondsOfSecond

    companion object {
        fun fromEpochSeconds(epochSeconds: Long, nanosecondAdjustment: Int = 0): Instant {
            var s = epochSeconds + (nanosecondAdjustment / 1_000_000_000).toLong()
            var n = nanosecondAdjustment % 1_000_000_000
            if (n < 0) { s -= 1; n += 1_000_000_000 }
            return Instant(s, n)
        }
        fun fromEpochMilliseconds(epochMilliseconds: Long): Instant {
            val s = epochMilliseconds / 1000L
            var n = ((epochMilliseconds % 1000L) * 1_000_000L).toInt()
            if (n < 0) return Instant(s - 1, n + 1_000_000_000)
            return Instant(s, n)
        }
        fun parse(input: String): Instant {
            val parts = __kxdt_parseInstant(input)
            return Instant(parts[0], parts[1].toInt())
        }
    }
}

class Duration internal constructor(
    val inWholeSeconds: Long,
    val nanosPart: Int,
) : Comparable<Duration> {
    val inWholeMilliseconds: Long get() = inWholeSeconds * 1000L + (nanosPart / 1_000_000).toLong()
    val inWholeMinutes: Long get() = inWholeSeconds / 60L
    val inWholeHours: Long get() = inWholeSeconds / 3600L
    val inWholeDays: Long get() = inWholeSeconds / 86_400L

    operator fun plus(other: Duration): Duration {
        var s = inWholeSeconds + other.inWholeSeconds
        var n = nanosPart + other.nanosPart
        if (n >= 1_000_000_000) { s += 1; n -= 1_000_000_000 }
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Duration(s, n)
    }
    operator fun minus(other: Duration): Duration = plus(Duration(-other.inWholeSeconds, -other.nanosPart))
    override fun compareTo(other: Duration): Int {
        if (inWholeSeconds != other.inWholeSeconds) return if (inWholeSeconds < other.inWholeSeconds) -1 else 1
        return nanosPart.compareTo(other.nanosPart)
    }
    override fun toString(): String = "${inWholeSeconds}s${nanosPart}n"

    companion object {
        fun seconds(value: Long): Duration = Duration(value, 0)
        fun seconds(value: Int): Duration = Duration(value.toLong(), 0)
        fun milliseconds(value: Long): Duration {
            val s = value / 1000L
            var n = ((value % 1000L) * 1_000_000L).toInt()
            if (n < 0) return Duration(s - 1, n + 1_000_000_000)
            return Duration(s, n)
        }
        fun milliseconds(value: Int): Duration = milliseconds(value.toLong())
        fun minutes(value: Long): Duration = Duration(value * 60L, 0)
        fun minutes(value: Int): Duration = minutes(value.toLong())
        fun hours(value: Long): Duration = Duration(value * 3600L, 0)
        fun hours(value: Int): Duration = hours(value.toLong())
        fun days(value: Long): Duration = Duration(value * 86_400L, 0)
        fun days(value: Int): Duration = days(value.toLong())
    }
}

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
// format-DSL members are intentionally absent.
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

// `actual` for upstream `expect class LocalDateTime`
// (LocalDateTime.kt). format-DSL members are intentionally absent.
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

fun Instant.toLocalDateTime(timeZone: TimeZone): LocalDateTime {
    val parts = __kxdt_instantToLocalParts(epochSeconds, nanosecondsOfSecond, timeZone.id)
    return LocalDateTime(parts[0].toInt(), parts[1].toInt(), parts[2].toInt(),
        parts[3].toInt(), parts[4].toInt(), parts[5].toInt(), parts[6].toInt())
}

fun LocalDateTime.toInstant(timeZone: TimeZone): Instant {
    val r = __kxdt_localToInstant(year, monthNumber, dayOfMonth, hour, minute, second, nanosecond, timeZone.id)
    return Instant(r[0], r[1].toInt())
}

interface Clock {
    fun now(): Instant
}

object SystemClock : Clock {
    override fun now(): Instant =
        Instant.fromEpochMilliseconds(__kxdt_currentTimeMillis())
            .let { Instant(it.epochSeconds, __kxdt_currentNanosOfSecond()) }
}

// ---------- DateTimePeriod ----------
//
// Calendar-aware delta. Used with Instant.plusPeriod(period, timeZone)
// so month/day arithmetic respects DST and varying month lengths via
// the host's chrono backend.

class DateTimePeriod(
    val years: Int = 0,
    val months: Int = 0,
    val days: Int = 0,
    val hours: Int = 0,
    val minutes: Int = 0,
    val seconds: Int = 0,
    val nanoseconds: Long = 0L,
) {
    val totalMonths: Int get() = years * 12 + months

    override fun toString(): String {
        val sb = StringBuilder("P")
        if (years != 0) sb.append(years).append('Y')
        if (months != 0) sb.append(months).append('M')
        if (days != 0) sb.append(days).append('D')
        val anyTime = hours != 0 || minutes != 0 || seconds != 0 || nanoseconds != 0L
        if (anyTime) {
            sb.append('T')
            if (hours != 0) sb.append(hours).append('H')
            if (minutes != 0) sb.append(minutes).append('M')
            if (seconds != 0 || nanoseconds != 0L) {
                sb.append(seconds)
                if (nanoseconds != 0L) sb.append('.').append(nanoseconds.toString().padStart(9, '0'))
                sb.append('S')
            }
        }
        if (sb.length == 1) sb.append("0D")
        return sb.toString()
    }
}

// Native helper: returns [epochSeconds, nanos] after applying the
// calendar period in the given tz.
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
): LongArray = longArrayOf(epochSeconds, nanos.toLong())

// Calendar-aware add. klio's overload resolver does not yet
// disambiguate `Instant.plus(Duration)` (member) from
// `Instant.plus(DateTimePeriod, TimeZone)` (extension) by signature,
// so the extension lives under a distinct name. Functionally
// equivalent to upstream's overloaded plus.
fun Instant.plusPeriod(period: DateTimePeriod, timeZone: TimeZone): Instant {
    val r = __kxdt_addPeriod(
        epochSeconds, nanosecondsOfSecond,
        period.years, period.months, period.days,
        period.hours, period.minutes, period.seconds, period.nanoseconds,
        timeZone.id,
    )
    return Instant(r[0], r[1].toInt())
}

fun Instant.minusPeriod(period: DateTimePeriod, timeZone: TimeZone): Instant = plusPeriod(
    DateTimePeriod(
        years = -period.years, months = -period.months, days = -period.days,
        hours = -period.hours, minutes = -period.minutes, seconds = -period.seconds,
        nanoseconds = -period.nanoseconds,
    ),
    timeZone,
)

// ---------- DateTimeUnit ----------
//
// Models units of date/time arithmetic. The sealed-class hierarchy
// follows upstream kotlinx.datetime: DateBased for whole-day units
// (Day/Week/Month/Year/etc.) and TimeBased for sub-day units
// (Nanosecond/Microsecond/Millisecond/Second/Minute/Hour). The
// klio surface plus host binding compose into Instant.plus(value,
// unit, tz) — calendar-aware for date units, fixed-nanosecond for
// time units.

class TimeBased(val nanoseconds: Long) {
    operator fun times(scalar: Int): TimeBased = TimeBased(nanoseconds * scalar.toLong())
}
class DateBased(val days: Int, val months: Int) {
    operator fun times(scalar: Int): DateBased = DateBased(days * scalar, months * scalar)
}

object DateTimeUnit {
    val NANOSECOND: TimeBased = TimeBased(1L)
    val MICROSECOND: TimeBased = TimeBased(1_000L)
    val MILLISECOND: TimeBased = TimeBased(1_000_000L)
    val SECOND: TimeBased = TimeBased(1_000_000_000L)
    val MINUTE: TimeBased = TimeBased(60L * 1_000_000_000L)
    val HOUR: TimeBased = TimeBased(3_600L * 1_000_000_000L)
    val DAY: DateBased = DateBased(1, 0)
    val WEEK: DateBased = DateBased(7, 0)
    val MONTH: DateBased = DateBased(0, 1)
    val QUARTER: DateBased = DateBased(0, 3)
    val YEAR: DateBased = DateBased(0, 12)
}

fun Instant.plusUnit(value: Long, unit: TimeBased): Instant {
    val totalNanos = value * unit.nanoseconds
    val nanoSec = totalNanos / 1_000_000_000L
    val nanoRem = totalNanos % 1_000_000_000L
    var s = epochSeconds + nanoSec
    var n = nanosecondsOfSecond + nanoRem.toInt()
    if (n >= 1_000_000_000) { s += 1; n -= 1_000_000_000 }
    if (n < 0) { s -= 1; n += 1_000_000_000 }
    return Instant(s, n)
}

fun Instant.plusDateUnit(value: Int, unit: DateBased, timeZone: TimeZone): Instant {
    val r = __kxdt_addPeriod(
        epochSeconds, nanosecondsOfSecond,
        0, unit.months * value, unit.days * value,
        0, 0, 0, 0L,
        timeZone.id,
    )
    return Instant(r[0], r[1].toInt())
}

fun Instant.minusUnit(value: Long, unit: TimeBased): Instant = plusUnit(-value, unit)
fun Instant.minusDateUnit(value: Int, unit: DateBased, timeZone: TimeZone): Instant =
    plusDateUnit(-value, unit, timeZone)

// ---------- Duration extension properties on Int/Long ----------
//
// kotlin.time-style fluent builders: `5.seconds`, `2L.hours`, etc.
// These return kotlinx.datetime.Duration, matching the rest of this
// layer. kotlin.time.Duration interop is deferred until stdlib
// carries it as a first-class type.

val Int.nanoseconds: Duration get() = Duration(0L, this)
val Int.microseconds: Duration get() = Duration(0L, this * 1_000)
val Int.milliseconds: Duration get() = Duration.milliseconds(this.toLong())
val Int.seconds: Duration get() = Duration.seconds(this.toLong())
val Int.minutes: Duration get() = Duration.minutes(this.toLong())
val Int.hours: Duration get() = Duration.hours(this.toLong())
val Int.days: Duration get() = Duration.days(this.toLong())

val Long.nanoseconds: Duration
    get() {
        val s = this / 1_000_000_000L
        val n = (this % 1_000_000_000L).toInt()
        return if (n < 0) Duration(s - 1, n + 1_000_000_000) else Duration(s, n)
    }
val Long.microseconds: Duration
    get() {
        val ns = this * 1_000L
        return ns.nanoseconds
    }
val Long.milliseconds: Duration get() = Duration.milliseconds(this)
val Long.seconds: Duration get() = Duration.seconds(this)
val Long.minutes: Duration get() = Duration.minutes(this)
val Long.hours: Duration get() = Duration.hours(this)
val Long.days: Duration get() = Duration.days(this)
